# Port of c/enc/cluster.{c,h} + cluster_inc.h. Upstream: 42a2ed4.

module Brotli
  module Enc
    struct HistogramPair
      property idx1 : UInt32
      property idx2 : UInt32
      property cost_combo : Float64
      property cost_diff : Float64

      def initialize(@idx1 = 0_u32, @idx2 = 0_u32,
                     @cost_combo = 0.0, @cost_diff = 0.0)
      end
    end

    # cluster.c:21
    private def self.histogram_pair_is_less(p1 : HistogramPair,
                                            p2 : HistogramPair) : Bool
      return p1.cost_diff > p2.cost_diff if p1.cost_diff != p2.cost_diff
      (p1.idx2 &- p1.idx1) > (p2.idx2 &- p2.idx1)
    end

    # cluster.c:30 — entropy reduction of the context map when combining.
    private def self.cluster_cost_diff(size_a : UInt32,
                                       size_b : UInt32) : Float64
      size_c = size_a &+ size_b
      size_a.to_f64 * fast_log2(size_a) +
        size_b.to_f64 * fast_log2(size_b) -
        size_c.to_f64 * fast_log2(size_c)
    end

    # cluster_inc.h:14 — computes the bit cost reduction of combining
    # out_[idx1] and out_[idx2]; pushes the pair to the bounded queue if good.
    # Returns the updated number of pairs.
    private def self.compare_and_push_to_queue(
        out_ : Array(Histogram), tmp : Histogram,
        cluster_size : Slice(UInt32), idx1 : UInt32, idx2 : UInt32,
        max_num_pairs : Int32, pairs : Slice(HistogramPair),
        num_pairs : Int32) : Int32
      is_good_pair = false
      p = HistogramPair.new
      return num_pairs if idx1 == idx2
      if idx2 < idx1
        idx1, idx2 = idx2, idx1
      end
      p.idx1 = idx1
      p.idx2 = idx2
      p.cost_diff = 0.5 * cluster_cost_diff(
        cluster_size.unsafe_fetch(idx1), cluster_size.unsafe_fetch(idx2))
      p.cost_diff -= out_[idx1].bit_cost
      p.cost_diff -= out_[idx2].bit_cost

      if out_[idx1].total_count == 0
        p.cost_combo = out_[idx2].bit_cost
        is_good_pair = true
      elsif out_[idx2].total_count == 0
        p.cost_combo = out_[idx1].bit_cost
        is_good_pair = true
      else
        threshold = num_pairs == 0 ? 1e99 : Math.max(0.0, pairs[0].cost_diff)
        tmp.copy_from(out_[idx1])
        tmp.add_histogram(out_[idx2])
        cost_combo = population_cost(tmp)
        if cost_combo < threshold - p.cost_diff
          p.cost_combo = cost_combo
          is_good_pair = true
        end
      end
      if is_good_pair
        p.cost_diff += p.cost_combo
        if num_pairs > 0 && histogram_pair_is_less(pairs[0], p)
          # Replace the top of the queue if needed.
          if num_pairs < max_num_pairs
            pairs[num_pairs] = pairs[0]
            num_pairs += 1
          end
          pairs[0] = p
        elsif num_pairs < max_num_pairs
          pairs[num_pairs] = p
          num_pairs += 1
        end
      end
      num_pairs
    end

    # cluster_inc.h:70 — collapses histograms until the cost reduction
    # threshold or the cluster limit is reached. Returns num_clusters.
    private def self.histogram_combine(out_ : Array(Histogram),
                                       tmp : Histogram,
                                       cluster_size : Slice(UInt32),
                                       symbols : Slice(UInt32),
                                       clusters : Slice(UInt32),
                                       pairs : Slice(HistogramPair),
                                       num_clusters : Int32,
                                       symbols_size : Int32,
                                       max_clusters : Int32,
                                       max_num_pairs : Int32) : Int32
      cost_diff_threshold = 0.0
      min_cluster_size = 1
      num_pairs = 0

      # Vector of histogram pairs; the pair with the maximum bit cost
      # reduction stays first.
      idx1 = 0
      while idx1 < num_clusters
        idx2 = idx1 + 1
        while idx2 < num_clusters
          num_pairs = compare_and_push_to_queue(
            out_, tmp, cluster_size,
            clusters.unsafe_fetch(idx1), clusters.unsafe_fetch(idx2),
            max_num_pairs, pairs, num_pairs)
          idx2 += 1
        end
        idx1 += 1
      end

      while num_clusters > min_cluster_size
        if pairs[0].cost_diff >= cost_diff_threshold
          cost_diff_threshold = 1e99
          min_cluster_size = max_clusters
          next
        end
        best_idx1 = pairs[0].idx1
        best_idx2 = pairs[0].idx2
        out_[best_idx1].add_histogram(out_[best_idx2])
        out_[best_idx1].bit_cost = pairs[0].cost_combo
        cluster_size[best_idx1] &+= cluster_size[best_idx2]
        i = 0
        while i < symbols_size
          symbols[i] = best_idx1 if symbols.unsafe_fetch(i) == best_idx2
          i += 1
        end
        i = 0
        while i < num_clusters
          if clusters.unsafe_fetch(i) == best_idx2
            # C: memmove(clusters+i, clusters+i+1, num_clusters-i-1 entries)
            ptr = clusters.to_unsafe
            (ptr + i).move_from(ptr + i + 1, num_clusters - i - 1)
            break
          end
          i += 1
        end
        num_clusters -= 1
        # Remove pairs intersecting the just combined best pair.
        copy_to_idx = 0
        i = 0
        while i < num_pairs
          p = pairs.unsafe_fetch(i)
          if p.idx1 == best_idx1 || p.idx2 == best_idx1 ||
             p.idx1 == best_idx2 || p.idx2 == best_idx2
            i += 1
            next
          end
          if histogram_pair_is_less(pairs[0], p)
            pairs[copy_to_idx] = pairs[0]
            pairs[0] = p
          else
            pairs[copy_to_idx] = p
          end
          copy_to_idx += 1
          i += 1
        end
        num_pairs = copy_to_idx

        # Push new pairs formed with the combined histogram.
        i = 0
        while i < num_clusters
          num_pairs = compare_and_push_to_queue(
          out_, tmp, cluster_size, best_idx1, clusters.unsafe_fetch(i),
            max_num_pairs, pairs, num_pairs)
          i += 1
        end
      end
      num_clusters
    end

    # cluster_inc.h:158 — bit cost of moving histogram to candidate.
    private def self.histogram_bit_cost_distance(histogram : Histogram,
                                                 candidate : Histogram,
                                                 tmp : Histogram) : Float64
      return 0.0 if histogram.total_count == 0
      tmp.copy_from(histogram)
      tmp.add_histogram(candidate)
      population_cost(tmp) - candidate.bit_cost
    end

    # cluster_inc.h:174 — find the best out-histogram per in-histogram,
    # then rebuild out from raw histograms + symbols.
    private def self.histogram_remap(input : Array(Histogram),
                                     in_size : Int32,
                                     clusters : Slice(UInt32),
                                     num_clusters : Int32,
                                     out_ : Array(Histogram), tmp : Histogram,
                                     symbols : Slice(UInt32)) : Nil
      i = 0
      while i < in_size
        best_out = i == 0 ? symbols.unsafe_fetch(0) : symbols.unsafe_fetch(i - 1)
        best_bits = histogram_bit_cost_distance(input[i],
                                                out_[best_out], tmp)
        j = 0
        while j < num_clusters
          cur_bits = histogram_bit_cost_distance(
            input[i], out_[clusters.unsafe_fetch(j)], tmp)
          if cur_bits < best_bits
            best_bits = cur_bits
            best_out = clusters.unsafe_fetch(j)
          end
          j += 1
        end
        symbols[i] = best_out
        i += 1
      end

      i = 0
      while i < num_clusters
        out_[clusters.unsafe_fetch(i)].clear
        i += 1
      end
      i = 0
      while i < in_size
        out_[symbols.unsafe_fetch(i)].add_histogram(input[i])
        i += 1
      end
    end

    # cluster_inc.h:213 — canonicalizes symbols[] to 0..N-1 in first-seen
    # order; reorders out_[]. Returns N.
    private def self.histogram_reindex(out_ : Array(Histogram),
                                       symbols : Slice(UInt32),
                                       length : Int32) : Int32
      k_invalid_index = UInt32::MAX
      new_index = Slice(UInt32).new(length, k_invalid_index)
      next_index = 0_u32
      i = 0
      while i < length
        if new_index.unsafe_fetch(symbols.unsafe_fetch(i)) == k_invalid_index
          new_index[symbols.unsafe_fetch(i)] = next_index
          next_index &+= 1
        end
        i += 1
      end
      tmp = Array(Histogram).new(next_index) { |k| Histogram.new(out_[k].data_size) }
      next_index = 0_u32
      i = 0
      while i < length
        if new_index.unsafe_fetch(symbols.unsafe_fetch(i)) == next_index
          tmp[next_index].copy_from(out_[symbols.unsafe_fetch(i)])
          next_index &+= 1
        end
        symbols[i] = new_index.unsafe_fetch(symbols.unsafe_fetch(i))
        i += 1
      end
      i = 0
      while i < next_index
        out_[i].copy_from(tmp[i])
        i += 1
      end
      next_index.to_i32!
    end

    # cluster_inc.h:251 — BrotliClusterHistograms.
    def self.cluster_histograms(input : Array(Histogram),
                                max_histograms : Int32,
                                out_ : Array(Histogram),
                                histogram_symbols : Slice(UInt32)) : Int32
      in_size = input.size
      cluster_size = Slice(UInt32).new(in_size, 1_u32)
      clusters = Slice(UInt32).new(in_size)
      num_clusters = 0
      max_input_histograms = 64
      pairs_capacity = max_input_histograms * max_input_histograms // 2
      # For the first pass of clustering, we allow all pairs.
      pairs = Slice(HistogramPair).new(pairs_capacity + 1) { HistogramPair.new }
      tmp = Histogram.new(input.empty? ? 0 : input[0].data_size)

      i = 0
      while i < in_size
        out_[i].copy_from(input[i])
        out_[i].bit_cost = population_cost(input[i])
        histogram_symbols[i] = i.to_u32!
        i += 1
      end

      i = 0
      while i < in_size
        num_to_combine = Math.min(in_size - i, max_input_histograms)
        j = 0
        while j < num_to_combine
          clusters[num_clusters + j] = (i + j).to_u32!
          j += 1
        end
        num_clusters += histogram_combine(
          out_, tmp, cluster_size,
          histogram_symbols + i, clusters + num_clusters, pairs,
          num_to_combine, num_to_combine, max_histograms, pairs_capacity)
        i += max_input_histograms
      end

      # Second pass: limit the total number of histogram pairs.
      max_num_pairs = Math.min(64 * num_clusters,
                               (num_clusters // 2) * num_clusters)
      if max_num_pairs + 1 > pairs.size
        bigger = Slice(HistogramPair).new(max_num_pairs + 1) { HistogramPair.new }
        bigger.copy_from(pairs)
        pairs = bigger
      end

      # Collapse similar histograms.
      num_clusters = histogram_combine(out_, tmp, cluster_size,
                                       histogram_symbols, clusters, pairs,
                                       num_clusters, in_size,
                                       max_histograms, max_num_pairs)

      # Find the optimal map from original histograms to the final ones.
      histogram_remap(input, in_size, clusters, num_clusters, out_, tmp,
                      histogram_symbols)
      # Convert the context map to a canonical form.
      histogram_reindex(out_, histogram_symbols, in_size)
    end
  end
end
