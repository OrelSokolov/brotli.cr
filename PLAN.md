# brotli.cr — порт Brotli на Crystal

Цель: чистокристальный декодер и энкодер Brotli (RFC 7932). Декодер —
для расшифровки WOFF2 в freetype.cr; энкодер (порт c/enc, q0–q11) —
для сборки ассетов (brotli-компрессия в Rails-подобных пайплайнах).

## Референс

- `upstream/brotli` — клон google/brotli (read-only, точка сравнения).
  Зафиксирован на: 42a2ed4 (2026-09-30).

## Объём порта

| Upstream | Строк | Назначение | Crystal |
|---|---|---|---|
| `c/dec/bit_reader.{c,h}` | ~500 | битовый ридер | `src/brotli/bit_reader.cr` |
| `c/dec/huffman.{c,h}` | ~460 | Huffman-таблицы | `src/brotli/huffman.cr` |
| `c/dec/prefix.c` + `prefix_inc.h` | ~760 | таблицы dist/extrabits (данные) | `src/brotli/prefix.cr` |
| `c/dec/state.{c,h}` | ~580 | состояние декодера | `src/brotli/state.cr` |
| `c/dec/decode.c` | 3023 | главный автомат | `src/brotli/decode.cr` |
| `c/common/context.{c,h}` | ~270 | ContextLookup-таблицы | `src/brotli/context.cr` |
| `c/common/transform.{c,h}` | ~380 | 121 трансформация | `src/brotli/transform.cr` |
| `c/common/dictionary*.{c,h}` | ~5900 | статический словарь (~122 КБ) | `src/brotli/dictionary.cr` (генерировать скриптом из `dictionary_inc.h`) |
| `c/common/constants.*`, `platform.h` | ~900 | константы | разложить по модулям |

Out of scope: `c/enc/**`, `c/common/shared_dictionary.c` (расширение
shared dictionaries — в WOFF2 не встречается), large-window флаг можно
поддержать позже (в WOFF2 не используется).

## Фазы

### 0. Оракул — ВЫПОЛНЕНО
Собрать C-декодер из upstream в CLI-оракул (`tmp_c/`): входной `.br`
файл → распакованные байты + код ошибки на stderr. Это эталон для всех
дифтестов (паттерн freetype.cr: `oracle_main.c` / `oracle_lib.cr`).
Результат: `tmp_c/brotli_oracle`, 22/22 roundtrip на testdata;
TRUNCATED/ERROR-режимы проверены.

### 1. Bit reader — ВЫПОЛНЕНО
`bit_reader.cr`: 64-битный аккумулятор, `BrotliTakeBits/PeakBits`,
pull-механика. Юнит-тесты на битовых последовательностях из RFC 7932
(приложение с примерами потоков). В_hot-арифметике сразу `&+`/`&-`.
Результат: `src/brotli/bit_reader.cr` + `spec/bit_reader_spec.cr`
(10 тестов, независимый LSB-first эталон в спеке). Указатели заменены
индексами; вход обязан иметь ≥64 байт slack после логического конца.
`Pointer#read` недоступен в Crystal 1.21 — load32le собирается из байт
(перф-проход в фазе 7).

### 2. Huffman + prefix — ВЫПОЛНЕНО
`huffman.cr` (построение таблиц по code lengths, простая/сложная
группа), таблицы prefix/context/transform/dictionary — в
`tables_data.cr` / `dictionary_data.cr` (генератор `tools/dump_tables.c`).

### 3. Автомат метаблоков — ВЫПОЛНЕНО
`decoder.cr` (порт state.c + decode.c в одном файле, one-shot
`Decoder#decode`). Контрольная точка пройдена: весь
`tests/testdata/*.compressed*` (45 файлов, включая `*.compressed.NN`
обрезки) — побайтово и по кодам выхода против `tmp_c/brotli_oracle`
(`tools/diff_test.sh`). CLI `bin/brotli_decode` — зеркало оракула
(exit 0/1/2, `ERROR code=N` / `TRUNCATED`).

### 4. Словарь, трансформации, контексты — ВЫПОЛНЕНО
Вместе с фазой 3: словарная ветка CommandPostDecodeLiterals,
`transform.cr`, контексты. Найден и исправлен баг порта IMTF
(`mtf[0] = value`, а не `mtf[1]` — соответствует C `mtf_u8[-1]`).

### 5. Коды ошибок — ВЫПОЛНЕНО
`tools/mutation_test.cr`: бит-флипы/обрезки/byte-smash 22 базовых
файлов testdata, 40 мутаций на файл (902 кейса) — 100% совпадение
результата и кода ошибки с оракулом. Для отладки собиралась
инструментированная копия C-декодера (`tmp_c/dbg/brotli_oracle_dbg`,
трассы BR_TRACE/BR_DUMP; upstream не тронут).

### 6. Дифференциальные корпуса — ВЫПОЛНЕНО
1. `upstream/brotli/tests/testdata` — 45/45 (`tools/diff_test.sh`).
2. Silesia corpus (`tmp/silesia`, 12 файлов × q0..q11 = 144 потока,
   сжато C-энкодером из upstream — `tmp_c/brotli_cli`,
   `tools/compress_silesia.sh`) — 144/144 побайтово и по кодам выхода.
3. WOFF2 (боевой сценарий): 173 `.woff2` с fonts.gstatic.com (34 семьи,
   `tools/download_fonts.sh`); ground truth — `woff2_decompress` из
   google/woff2 (`/tmp/woff2/build`, собран из клона). Бротli-поток
   извлекается экстрактором `tools/woff2_brotli.cr` (порт подмножества
   парсера woff2_dec.cc: в WOFF2 весь блок таблиц — ОДИН brotli-поток
   в header.compressed_offset/compressed_length). Итог
   (`tools/woff2_test.sh`): 173/173 — побайтово против оракула, длина
   декодированного == uncompressed-размеру из директории таблиц woff2.
   Финальная интеграция — в freetype.cr.

### 7. Производительность — ВЫПОЛНЕНО (1.66x)
`tools/bench.sh`, Silesia q9 (211 МБ выхода): C 255 МБ/с, порт
154 МБ/с — 1.65x; q11: 1.66x. Цель ≤2x достигнута без отдельного
perf-прохода (`&+`/`&-`/`unsafe_fetch` уже в горячих путях); запас на
оптимизацию остаётся (IO::Memory → плоский буфер, load32le).

## HANDOFF: детальный план фазы 3 (decoder.cr) — ВЫПОЛНЕНО

Статус на 2026-10-05: фазы 0–5 готовы. `decoder.cr` написан по этому
плану и проверен дифтестами (45/45 testdata) и мутационными тестами
(902/902). План ниже сохранён как документация принятых решений.
Предыстория: фазы 0–2 (`bit_reader.cr`, `huffman.cr`,
`constants.cr`, `types.cr`, `tables_data.cr` [CONTEXT_LOOKUP,
PREFIX_CODE_RANGES, TRANSFORM_*, CMD_LUT, DICTIONARY_*],
`dictionary_data.cr` [DICTIONARY_DATA, 122784 байта], `transform.cr`).
`upstream/` = google/brotli @ 42a2ed4. Oracle: `tmp_c/brotli_oracle`
(`brotli_oracle <in.br> [out]`; exit 0 OK / 1 error (`ERROR code=N` на
stderr) / 2 truncated). Всё ниже — выведенные решения для порта
`state.c` + `decode.c` → один файл `src/brotli/decoder.cr`; читается
вместе с upstream-исходниками, все номера строк — decode.c @ 42a2ed4.

### Дизайн

- Класс `Brotli::Decoder`; one-shot: `Decoder#decode(input : Bytes) : Bytes`
  (raise `Brotli::DecodeError` с `code`). Коды = C-значения: SUCCESS=1,
  NEEDS_MORE_INPUT=2, NEEDS_MORE_OUTPUT=3; ошибки — отрицательные (список
  ниже). CLI отличит truncated (code==2) от ошибки (code<0) — как оракул.
- One-shot упрощение: внутренний 8-байтовый буфер `s->buffer` и вся
  переливка input в `BrotliDecoderDecompressStream` (decode.c:2447–2546)
  НЕ портируется. Вход копируется в `Bytes.new(size + 64)` (64 байта slack
  ≥ FAST_INPUT_SLACK=28 — контракт bit_reader.cr), `br.set_input(0, size)`.
  NEEDS_MORE_INPUT на конце входа = truncated (code 2). Перед этим
  обязательно выполняется проактивный `write_ring_buffer(force: true)`
  (там может всплыть BLOCK_LENGTH_1 — важно для мутационных тестов).
- Выход: `IO::Memory` (без ограничений ⇒ NEEDS_MORE_OUTPUT невозможен,
  `num_written == to_write` всегда).
- Out of scope (пути вырезаны, compat с оракулом по умолчанию):
  compound dictionary (compound_dictionary_size ≡ 0), attached/shared
  dictionary, large window (`DecodeWindowBits` отдаёт FORMAT_WINDOW_BITS
  на маркер 0x11 — как C без флага), metadata callbacks (SkipMetadataBlock
  по-прежнему вычитывает байты).
- Точность важна: все `BROTLI_FAILURE(...)` на тех же местах ⇒ совпадение
  error codes с оракулом побитно.

### Коды ошибок (decode.h, BROTLI_DECODER_ERROR_CODES_LIST)

NO_ERROR=0, SUCCESS=1, NEEDS_MORE_INPUT=2, NEEDS_MORE_OUTPUT=3,
FORMAT_EXUBERANT_NIBBLE=-1, FORMAT_RESERVED=-2, FORMAT_EXUBERANT_META_NIBBLE=-3,
FORMAT_SIMPLE_HUFFMAN_ALPHABET=-4, FORMAT_SIMPLE_HUFFMAN_SAME=-5,
FORMAT_CL_SPACE=-6, FORMAT_HUFFMAN_SPACE=-7, FORMAT_CONTEXT_MAP_REPEAT=-8,
FORMAT_BLOCK_LENGTH_1=-9, FORMAT_BLOCK_LENGTH_2=-10, FORMAT_TRANSFORM=-11,
FORMAT_DICTIONARY=-12, FORMAT_WINDOW_BITS=-13, FORMAT_PADDING_1=-14,
FORMAT_PADDING_2=-15, FORMAT_DISTANCE=-16, FORMAT_BLOCK_SWITCH=-17,
COMPOUND_DICTIONARY=-18, DICTIONARY_NOT_SET=-19, INVALID_ARGUMENTS=-20,
ALLOC_CONTEXT_MODES=-21, ALLOC_TREE_GROUPS=-22, ALLOC_CONTEXT_MAP=-25,
ALLOC_RING_BUFFER_1=-26, ALLOC_RING_BUFFER_2=-27, ALLOC_BLOCK_TYPE_TREES=-30,
UNREACHABLE=-31.

### Поля состояния (state.h → Decoder)

- C-union arena.header/arena.body → просто все поля класса. Требуемые:
  state, loop_counter, br, pos, max_backward_distance, max_distance,
  ringbuffer_size, ringbuffer_mask, dist_rb_idx, dist_rb[4] (старт
  16,15,11,4), error_code, meta_block_remaining_len, ringbuffer,
  htree_command, context_lookup_offset (= mode<<9; CONTEXT =
  LUT[off+p1] | LUT[off+256+p2]), context_map_slice/dist_context_map_slice
  (subslice Bytes), literal/insert_copy/distance_hgroup (класс
  HuffmanTreeGroup из huffman.cr), block_type_trees/block_len_trees,
  trivial_literal_context, distance_context, block_length[3],
  block_length_index, num_block_types[3], block_type_rb[6],
  distance_postfix_bits, num_direct_distance_codes, num_dist_htrees,
  dist_context_map, literal_htree, rb_roundtrips/partial_pos_out (Int64!),
  mtf/mtf_upper_bound, copy_length, distance_code, dist_htree_index,
  is_* флаги, window_bits, size_nibbles, num_literal_htrees, context_map,
  context_modes, trivial_literal_contexts[8] (UInt32), substate_* (все 7
  enum'ов), new_ringbuffer_size, output, varlen_uint8_value.
- Header-arena поля: sub_loop_counter, repeat_code_len, prev_code_len,
  symbol, repeat, space, table (Slice(HuffmanCode), 32),
  symbols_lists_array (Slice(UInt16), 720), next_symbol (Slice(Int32), 32),
  code_length_code_lengths (Bytes, 18), code_length_histo
  (Slice(UInt16), 16), htree_index, next_offset (+ ссылка на текущую
  группу), context_index, max_run_length_prefix, code,
  context_map_table (Slice(HuffmanCode), HUFFMAN_MAX_SIZE_272).
- Body-arena: dist_extra_bits (Bytes, 544), dist_offset (Slice(Int32),
  544; alphabet_limit ≤ 520 < 544).
- @space — **UInt32 с &-/** (underflow = сигнал ошибок CL_SPACE /
  HUFFMAN_SPACE; проверка `space - 1 >= 32` у C — беззнаковая).
- Мелкие таблицы в decoder.cr: CODE_LENGTH_CODE_ORDER (18),
  CODE_LENGTH_PREFIX_LENGTH/VALUE (16) — decode.c:49–62.
- block_type_trees = Slice(HuffmanCode).new(3*(632+396));
  block_len_trees = block_type_trees + 3*632 (Slice#+ — тот же буфер).

### КРИТИЧНО: конвенция symbol_lists (biased flat array)

huffman.cr уже использует плоский слайс с SYMBOL_LISTS_BASE=16:
`flat[i] == C symbol_lists[i - 16]`. Головы длин l∈1..15 лежат в flat[l],
цепочки символов s∈0..703 — в flat[16+s]. Правила заполнения из decode:

- init (ReadHuffmanCode, decode.c:887): `next_symbol[i] = i` и
  `flat[i] = 0xFFFF` для i∈1..15 (C: next_symbol[i]=i-16 — смещение уже
  зашито в base).
- ProcessSingleCodeLength (decode.c:577): `flat[next_symbol[len]] = symbol`
  (значение — RAW символ!), `next_symbol[len] = symbol + 16` (biased
  позиция следующей записи). `space &-= 32768 >> len`; histo[len] += 1.
- ProcessRepeatedCodeLength (decode.c:604): biased-вариант C-цикла:
  `last = symbol + repeat_delta; next = next_symbol[len]; loop {
  flat[next] = symbol; next = symbol + 16; symbol += 1 } until symbol ==
  last; next_symbol[len] = next`. Переполнение алфавита: symbol +
  repeat_delta > alphabet_size ⇒ symbol = alphabet_size, space = 0xFFFFF.
- ReadSimpleHuffmanSymbols пишет RAW значения в flat[0..3] (без bias) —
  их же получает build_simple_huffman_table(val = flat) и сортирует
  in place.
- build_huffman_table(table, 8, flat, histo): индексация head'ов
  flat[SYMBOL_LISTS_BASE + (len-16)] = flat[len] — уже сходится.

### Индексация двухуровневых таблиц (HuffmanCode.value — offset ОТ СВОЕГО индекса)

- decode_symbol (decode.c:362): `i0 = bits & 0xFF; e = t[i0]`;
  если e.bits > 8: drop(8); `i2 = i0 + e.value + ((bits >> 8) &
  BitReader.bit_mask(e.bits - 8))`; e = t[i2]. drop(e.bits); → e.value.
- safe_decode_symbol (decode.c:387) — точно по C (0 бит в аккумуляторе ⇒
  успех при e.bits==0, иначе false; `(val & mask(e.bits)) >> 8`;
  `i2 = i0 + e.value + val`).
- read_preloaded_symbol (decode.c:454): `idx0 = (val & 0xFF) + prev_value`;
  ext = t[idx0]; drop(8); final = `idx0 + ext.value + ((val >> 8) &
  mask(bits - 8))`.
- read_symbol = decode_symbol(br.get16_bits_unmasked, t).
- preload_symbol: peek `br.get_bits(8)` → {e.bits, e.value} из t[val&0xFF].
- copy_preloaded_symbols_to_u8 (decode.c:478): new_lim =
  (guard_in - next_in)*8/15; pos_limit = min(limit, new_lim-4) (≥0);
  быстрый цикл до pos_limit, потом `while check_input_amount && copies <
  limit`. Возвращает {copies, bits, value}.

### Порции decode.c построчно

- DecodeWindowBits (146): как C, large_window всегда false ⇒ 0x11-маркер =
  FORMAT_WINDOW_BITS. window_bits из (17+n)&63 / (8+n)&63 / 16 / 17.
- DecodeVarLenUint8 (193): value персистится в @varlen_uint8_value между
  NEEDS_MORE_INPUT (C хранит в поле-приёмнике — семантика та же); финал
  `value = (1 << value) + bits`.
- DecodeMetaBlockLength (237): подstate-машина NONE→EMPTY→NIBBLES→SIZE→
  UNCOMPRESSED / RESERVED→BYTES→METADATA; exuberant nibble ⇒ -1/-3;
  reserved bit ⇒ -2; +1 к длине в конце.
- ReadHuffmanCode (807): сигнатура `read_huffman_code(max, limit,
  table : Slice(HuffmanCode), off : Int32) : {Int32, UInt32}` (код +
  table_size; писать через `codes + off`). Ветки NONE→SIMPLE_SIZE→
  SIMPLE_READ→SIMPLE_BUILD (symbol==3 ⇒ +1 бит tree_select) и →COMPLEX
  (ReadCodeLengthCodeLengths (751): static prefix по CODE_LENGTH_PREFIX_*;
  space UInt32 wrap; num_codes==1||space==0 иначе CL_SPACE) →
  LENGTH_SYMBOLS (ReadSymbolCodeLengths (652) / Safe (702); space != 0 ⇒
  HUFFMAN_SPACE; build_huffman_table).
- ReadBlockLength/SafeReadBlockLength (933/944): PREFIX_CODE_RANGES[code]
  — кортеж **{offset, nbits}** (порядок в tables_data.cr:139!).
- InverseMoveToFrontTransform (984): mtf = Bytes(257), bias 1 (mtf[0] ≡
  C mtf[-1]). Init: mtf[j] = j-1 для j ∈ 1...(upper_bound+1)*4. Цикл:
  `index = v[i]; value = mtf[index+1]; upper_bound |= v[i]; v[i] = value;
  mtf[1] = value; begin index -= 1; mtf[index+2] = mtf[index+1] end while
  index >= 0`. После: mtf_upper_bound = upper_bound >> 2.
- HuffmanTreeGroupDecode (1022): @next_offset от 0; htrees[i] =
  codes[next_offset, table_size]; group init: codes =
  Slice(HuffmanCode).new(ntrees * (limit + 376)).
- DecodeContextMap (1051): с флагом literal (→ num_literal_htrees/
  context_map | num_dist_htrees/dist_context_map); num_htrees ≤ 1 ⇒ нули;
  RLE zeros; repeat overflow ⇒ CONTEXT_MAP_REPEAT; IMTF по биту.
- DecodeBlockTypeAndLength (1180): max_block_type ≤ 1 ⇒ BLOCK_SWITCH;
  safe-путь с memento; при неудаче SafeReadBlockLength —
  substate_read_block_length = NONE и restore (откат! decode.c:1205).
- DetectTrivialLiteralBlockTypes (1226), PrepareLiteralDecoding (1245):
  context_map_slice = context_map + (block_type << 6); trivial bit из
  trivial_literal_contexts[b>>5] >> (b&31); literal_htree =
  literal_hgroup.htrees[slice[0]]; context_lookup_offset =
  (context_modes[b] & 3) << 9.
- WriteRingBuffer (1336): one-shot — start = partial_pos_out & mask;
  to_write = unwritten_bytes(wrap=true); remaining_len < 0 ⇒
  BLOCK_LENGTH_1; output.write(rb[start, to_write]); wrap: если
  ringbuffer_size == 1<<window_bits && pos >= ringbuffer_size: pos -=
  size, rb_roundtrips += 1, should_wrap = pos != 0. WrapRingBuffer
  (1381): rb[0,pos] ← rb[size,pos].
- BrotliEnsureRingBuffer (1395): new = Bytes(size + 542); [n-2]=[n-1]=0;
  copy старого rb[0,pos]; mask = size-1.
- SkipMetadataBlock (1424): drain аккумулятора copy_bytes, потом
  drop_bytes; NEEDS_MORE_INPUT если не хватило.
- CopyUncompressedBlockToOutput (1476): NONE (copy до границы окна; если
  pos < 1<<wbits и len>0 ⇒ NEEDS_MORE_INPUT) → WRITE (write_ring_buffer;
  max_distance = max_backward_distance при полном окне).
- BrotliCalculateRingBufferSize (1664): canny=true; min_size от pos+len;
  сокращать вдвое пока (new>>1) >= min_size.
- ReadContextModes (1704): по 2 бита на block type[0].
- TakeDistanceFromRingBuffer (1721): точный порт (delta из 0x605142).
- CalculateDistanceLut (1835): i от 16; ndirect прямых; регулярные:
  base = ndirect + ((((2+half) << bits) - 4) << npostfix) + 1; bits +=
  half; half ^= 1.
- ReadDistanceInternal (1870) / ReadCommandInternal (1918): точно по C
  (memento в safe; block_length[2]-- / [1]--; dist_htree_index =
  dist_context_map_slice[distance_context]).
- ProcessCommandsInternal (2005): goto → while-case по phase (:begin/
  :inner/:post_decode/:post_wrap/:next_literal_block/:exit); `s->state =
  ...` в safe-режиме выставлять как в C (для резюма); макросы BROTLI_SAFE
  развернуть руками. Словарная ветка: см. ниже.
- Главный цикл decode_stream: как DecompressStream (2447) без буфера
  подкачки; state-кейсы UNINITED→…→DONE по C; COMMAND_* →
  process_commands → safe_process_commands при NEEDS_MORE_INPUT;
  POST_WRITE_1: (compound пропущен) remaining==0 ⇒ METABLOCK_DONE else
  COMMAND_BEGIN; INNER_WRITE: loop_counter==0 ⇒ (remaining==0 ?
  METABLOCK_DONE : POST_DECODE_LITERALS) else COMMAND_INNER;
  METABLOCK_DONE: remaining<0 ⇒ BLOCK_LENGTH_2, jump_to_byte_boundary
  иначе PADDING_2; DONE: write_ring_buffer(force).

### Словарная ветка (CommandPostDecodeLiterals, decode.c:2200–2326)

compound ⇒ пропущен. Если `i` (copy_length) ∈ 4..31
(SHARED_BROTLI_{MIN,MAX}_DICTIONARY_WORD_LENGTH): dict_id=0,
num_dictionaries=1 ⇒ цикл выбора второго словаря (2251–2281) вырезан.
shift = DICTIONARY_SIZE_BITS_BY_LENGTH[i]; address = distance_code -
max_distance - 1; word_idx = address & ((1<<shift)-1); transform_idx =
address >> shift; dist_rb_idx += distance_context; offset =
DICTIONARY_OFFSETS_BY_LENGTH[i] + word_idx*i. size_bits[i]==0 ⇒
FORMAT_DICTIONARY. transform_idx ≥ NUM_TRANSFORMS ⇒ FORMAT_TRANSFORM.
transform_idx == 0 (cutOffTransforms[0]) ⇒ memcpy слова len=i; иначе
len = Transform.dictionary_word(rb, pos, DICTIONARY_DATA, offset, i,
transform_idx); len==0 && distance_code<=120 ⇒ FORMAT_TRANSFORM.
pos += len; remaining -= len; pos ≥ size ⇒ POST_WRITE_1. Иначе (i вне
4..31) ⇒ FORMAT_DICTIONARY. LZ77-ветка: memmove16; пересечение/заворот ⇒
CommandPostWrapCopy; иначе copy остатка (i>32 memcpy / >16 memmove16).

### Порядок работ после написания decoder.cr

1. `require` в src/brotli.cr: constants, types, tables_data,
   dictionary_data, huffman, transform, decoder. Проверка компиляции:
   `crystal eval 'require "./src/brotli"'`.
2. Починить spec/huffman_spec.cr (тест build_huffman_table содержит
   мусорный placeholder-код построения symbol_lists — переписать чисто на
   biased-конвенции из этого плана). `crystal spec`.
3. CLI `bin/brotli_decode` — зеркало oracle_main.c: same argv, same exit
   codes (0/1/2), stderr `ERROR code=N` / `OK <bytes>`; оракул читает
   целиком + цикл DecompressStream (у нас decode one-shot).
4. Диф: все `upstream/brotli/tests/testdata/*.compressed` (69 шт., включая
   `*.compressed.00..` обрезанные — там ожидается exit 2 TRUNCATED) —
   побайтово vs `tmp_c/brotli_oracle`.
5. Мутационные тесты (фаза 5): бит-флипы/обрезки ⇒ сравнить и результат,
   и код ошибки с оракулом.
6. Бенчмарк (фаза 7): МБ/с на Silesia против C, цель ≤2x; затем perf-проход
   (unsafe_fetch, &-арифметика, IO::Memory → плоский буфер).

## Критерии готовности

- [x] все `tests/testdata/*.compressed` — побайтово + совпадение кодов ошибок
      (`tools/diff_test.sh`: 45/45, включая `*.compressed.NN` обрезки)
- [x] Silesia (q0–q11) — побайтово (`tools/diff_test.sh tmp/silesia/br`: 144/144)
- [x] корпус WOFF2 — 173 шрифта Google Fonts (34 семьи), совпадение с оракулом
      побайтово + длина == uncompressed из woff2 (`tools/woff2_test.sh`: 173/173;
      ground truth-валидация каждого файла через `woff2_decompress`)
- [x] мутационные тесты: 100% совпадение error codes с оракулом
      (`tools/mutation_test.cr`: 902/902)
- [x] бенчмарк ≤ 2x от C (`tools/bench.sh`: Silesia q9 — 1.65x, q11 — 1.66x)

---

# Энкодер: план порта c/enc (q0–q11)

Утверждённый план (полная версия: `tmp/encoder_plan.md`). Совместимость =
корректный RFC 7932 поток (двойной roundtrip: наш декодер + C-оракул),
байтовая идентичность выводу C-энкодера НЕ требуется; ratio vs C — метрика
качества. API: one-shot `Brotli.encode(input, quality, lgwin)`.

Out of scope: streaming API, large window (lgwin>24, композиты/rolling),
SIMD-хэшеры (скалярные H5/H6 эквивалентны), compound/shared словари,
base64-regions, MemoryManager (есть GC).

## Фазы

### E0. Таблицы — ВЫПОЛНЕНО
`tools/dump_tables.c` расширен: base64-блобы `DICT_HASH_WORDS/LENGTHS`,
`STATIC_DICTIONARY_BUCKETS`, `STATIC_DICTIONARY_WORDS_{LEN,TRANSFORM,IDX}`
(u16 LE, генерятся через `le_u16`), литералы entropy_encode_static
(`CODE_LENGTH_*`, `STATIC_{COMMAND,DISTANCE}_CODE_*`, `{ZERO,NON_ZERO}_REPS_*`)
→ `src/brotli/enc/enc_tables_data.cr` (429 КБ; `tools/gen_tables.sh` с
argv[2]). Спека `spec/enc_tables_spec.cr`: FNV-1a64-контрольные суммы
(захардкожены из C-дампера), размеры, Kraft для префикс-кодов, границы
элементов. 26/26 spec, декодер не тронут (diff_test 45/45).
Нюансы: reps-таблицы — не префикс-коды (depth = суммарные биты RLE-всплеска,
до 30); `WORDS[0]` — сантинел (len=0); слоты buckets начинаются с 1.

### E1. Инфраструктура
`enc/bit_writer.cr` (write_bits/update_bits/rewind), `enc/command.cr`,
`enc/params.cr` (SanitizeParams/ComputeLgBlock/ChooseHasher/
CalculateDistanceLUT), `enc/entropy_encode.cr`, `enc/match_cost.cr`
+ юнит-спеки.

### E1. Инфраструктура — ВЫПОЛНЕНО
`enc/bit_writer.cr` (write_bits LSB-first ≤56 бит, update_bits — in-place
патч MLEN, rewind_bit_position с маскировкой хвоста), `enc/command.cr`
(Command-структура {insert_len, copy_len+7-битный delta, dist_prefix/extra},
insert/copy length codes, combine_length_codes, prefix_encode_copy_distance,
restore_distance_code, distance_context), `enc/params.cr` (Mode/Params/
HasherParams/DistanceParams, sanitize_params!, compute_lg_block/rb_bits,
max_metablock_size, choose_hasher — без SIMD/large-window веток,
init_distance_params), `enc/entropy_encode.cr` (create_huffman_tree c
count_limit-циклом, set_depth, convert_bit_depths_to_symbols c реверсом
бит, write_huffman_tree RLE 16/17, optimize_huffman_counts_for_rle 24.8
fixed point), `enc/match_cost.cr` (log2_floor/fast_log2,
find_match_length_with_limit 8-байтовым XOR + TZCNT, mostly_utf8?).
Спеки: 30 новых (bit_writer — независимый LSB-ридер, command — полное
покрытие InsBase/CopyBase против таблиц и CMD_LUT декодера (24×24),
prefix_encode против RFC-референса + roundtrip restore, entropy — Kraft-
равенство, лимит глубины на Фибоначчи, декодирование наших кодов ТАБЛИЦАМИ
ДЕКОДЕРА (huffman.cr), RLE-реконструкция с иерархической семантикой
(repeat-2)<<bits, match_cost — против наивных реализаций). Итог: 56/56
spec, diff_test 45/45. Найденные при отладке порта баги: потерянный
`continue` в set_depth (спуск влево проваливался в pop-секцию), лишний
`&` вместо `&-` в restore_distance_code, Command.insert нельзя выражать
через prefix_encode(16) — граница 16 уходит в регулярную ветку.

### E2. q0 (compress_fragment one-pass) → первый рабочий энкодер — ВЫПОЛНЕНО
`enc/compress_fragment.cr` (OnePassArena, state machine по C-меткам
emit_commands/emit_remainder/next_block, `goto emit_remainder` = raise
RemainderSignal, `goto trawl` влит в цикл скана), `enc/bit_stream.cr`
(store_huffman_tree с RLE, build_and_store_huffman_tree_fast,
store_static_code_length_code), `enc/encoder.cr` (q0 → encode_one_pass,
фрагментация по 1<<lgwin, lgwin ≥ 18). Тесты: `tools/encode_test.sh`
24/24 testdata (двойной roundtrip: наш декодер + C-оракул), Silesia
q0 12/12 roundtrip, суммарно −0.46% vs C; краевые случаи (пусто, 1 байт,
random 300KB/700KB, >256KB multi-fragment) OK. 56 spec зелёные,
diff_test 45/45. Найденный баг порта: K_CMD_HISTO_SEED был 123 элемента
вместо 128 (обрезан хвост) — seed обязан покрывать ненулевым счётчиком
все символы с дефолтными глубинами, иначе при пересборке деревьев в
cmd_depth остаются stale-глубины → пересуженное дерево и мусорные
команды со 2-го метаблока. Инструменты: `tmp_c/enc_roundtrip.cr`
(бинарник `tmp_c/enc_roundtrip`, API: `enc_roundtrip <q> <in> <out> [dec]`).

### E3. q1 (compress_fragment_two_pass; свой CommandPrefixCode shuffle!) — ВЫПОЛНЕНО
`enc/compress_fragment_two_pass.cr` (TwoPassArena, двухпроходная схема:
create_commands → буферы команд/литералов → store_commands с деревьями по
фактическим гистограммам; ДРУГОЙ shuffle командного префикс-кода, свои
EmitInsertLen/CopyLen/Distance с кодировкой code | extra<<8, маркер
последней дистанции = 64, таблицы kNumExtraBits/kInsertOffset,
ShouldCompress через bits_entropy, uncompressed-фолбэк с
rewind; min_match 4/6 по table_bits ≤/> 15, включая upstream-типу в
min-match-4 пост-копи апдейте — offset 0 вместо 2, портирован faithfully),
`enc/bit_cost.cr` (bits_entropy), encoder.cr: encode_fast(one_pass) —
общий фрагментный цикл q0/q1 (odd-shift fixup только q0). Тесты:
encode_test.sh q1 24/24 testdata (двойной roundtrip), краевые (пусто,
1 байт, random 300K/700K, >256K, abc-400K) OK, Silesia q1 12/12
roundtrip, суммарно −1.1% vs C. 56 spec зелёные.

### E4. Хэшеры H2/H3/H4/H54 + greedy/lazy → q2, q3 (StoreMetaBlockFast/Trivial)

ВЫПОЛНЕНО. Файлы: `enc/hashers.cr` (QuicklyHasher h2/h3, prepare/store/
store_range/stitch_to_previous_block/find_longest_match), `enc/static_dict.cr`
+ `enc/encoder_dict.cr` (EncoderDictionary.default, поиск в статик-словаре
с трансформами, cutoffTransforms), `enc/backward_references.cr`
(create_backward_references: greedy+lazy до 4 задержек, random-heuristics
скачки, compute_distance_code с шорт-кодами кэша), `enc/command.cr`
(Command: copy_len 25 бит + delta<<25, dist_prefix code|nbits<<10,
Command.insert), `enc/bit_stream.cr` (store_meta_block_fast q≤2:
статические cmd/dist-деревья при ≤128 командах, иначе BuildFast по
гистограммам; store_meta_block_trivial q3; build_histograms/
store_data_with_huffman_codes; store_uncompressed + откат dist_cache),
`enc/params.cr` (choose_hasher, compute_lg_block, init_distance_params),
encoder.cr: encode_blocks.

Схема encode_blocks (одноваттовый аналог EncodeData): фрагменты 1<<lgwin;
rb = фрагмент, паддингованный до степени двойки (mask = rb−1, без wrap);
хэшер fresh на фрагмент (one_shot=true, frag), stitch после каждого блока;
блоки 1<<lgblock = метаблоки; should_compress? (гистограммный энтропийный
фильтр encode.c:466) с uncompressed-фолбэком и откатом dist_cache;
last_bytes переносится между фрагментами.

Ключевые нюансы, найденные отладкой:
1) Хвостовая insert-команда эмитится на КАЖДЫЙ блок (encode.c:1181),
   не только на is_last — иначе блок без copy-команд даёт метаблок
   с пустым списком команд и непокрытым MLEN (FORMAT_PADDING/десинк).
   При last_insert_len == 0 не эмитится.
2) dist_cache инициализируется {4,11,15,16} ОДИН раз и переносится
   через границы фрагментов: поток непрерывен, декодерный dist-ринг
   не сбрасывается — шорт-коды дистанций 0..15 во 2+ фрагменте читались
   бы из чужого кэша (ловится как FORMAT_DISTANCE −16 через
   TakeDistanceFromRingBuffer → 0x7FFFFFFF).
3) Короткие дист-коды дают dist_rb[last]+delta; отрицательные значения
   декодер превращает в INT_MAX и фейлит.
4) dictionary_start для статик-словаря считается от АБСОЛЮТНОЙ позиции
   (pos + frag_pos, как C position_offset=stream_offset): дистанция
   словарного матча должна превышать min(abs_pos, max_backward_limit)
   декодера, иначе он возьмёт обычный LZ77-copy вместо словарной ветки
   (при copy_len_code = word_len > matchlen это даёт +delta к покрытию
   блока → FORMAT_BLOCK_LENGTH_2 −10).

Тесты: encode_test q2/q3/q0/q1 24/24 (оракул + собственный декодер),
56 spec, краевые (пусто, 1 байт, random 64K/1M, abc-400K — RLE хуже C,
q2 538 vs 25: нет длинных RLE-матчей вне блоков, задокументировано),
Silesia q2/q3 12/12 roundtrip.

### E5. Конвейер q4–q9 — ВЫПОЛНЕНО
`enc/histogram.cr`, `enc/bit_cost.cr`, `enc/cluster.cr`, `enc/block_splitter.cr`,
`enc/metablock.cr` (BuildMetaBlockGreedy, ContextBlockSplitter,
DecideOverLiteralContextModeling, OptimizeHistograms), `enc/literal_cost.cr`,
`enc/bit_stream.cr`: BlockEncoder + StoreMetaBlock + EncodeContextMap (MTF+RLE),
`enc/hashers.cr`: H5/H6 (longest match), H40–42 (forgetful chain),
encoder.cr: encode_metablocks (один метаблок на фрагмент окна,
uncompressed-фолбэк `frag + 4 < w.pos >> 3` с откатом dist_cache/storage).
Найденный баг порта (критичный для ratio): в LongestMatchHasher индекс бакета
`(i & block_mask) &+ bucket_offset` вычислялся в UInt16 (у Crystal битовые/
арифметические операторы сохраняют тип приёмника: UInt16 & UInt32 → UInt16) и
обрезал `key << block_bits` (до 8 МБ) по модулю 65536 — записи и чтения цепей
ходили в согласованные но ЧУЖИЕ слоты: поток валиден, но матчи терялись
(compressed_repeated q9 давал 100523 вместо 50443, тексты q9 ~+14%).
Фикс: вся индексация бакетов в Int32 (store/find_longest_match).
Диагностика: инструментированная копия C-энкодера `tmp_c/enc_dbg`
(BR_ENC_TRACE=1 печатает команды CreateBackwardReferences).
Тесты: encode_test q4–q9 testdata 24/24 (двойной roundtrip), Silesia q4–q9
13/13, краевые (пусто, 1 байт, abc-400K, random ×2) OK, lgwin=16 (H40/41/42)
roundtrip q0–q9 OK, 56 spec зелёные. Ratio vs C: текстовые файлы q4/q9 побайтово равны C
(alice29/lcet10/plrabn12/compressed_repeated), Silesia суммарно
+0.6%…+2.5% (q5…q9, в целевых ±5%; детали tmp/e5_notes.md).

### E6. HQ q10–q11: static_dict (reuse transform.cr), H10 binary tree,
Zopfli DP (Float32!), BrotliBuildMetaBlock.

### E7. CLI `bin/brotli_encode` + `tools/encode_test.sh` (двойной roundtrip
всех q на testdata/Silesia/шрифтах/ассетах; краевые: пусто, 1 байт, random,
>64MB, UTF8/binary) + отчёт ratio vs C.

### E8. Производительность: цель ≤3x от C на q1/q5/q9 (q11 — зафиксировать).
