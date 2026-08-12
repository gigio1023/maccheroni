# Glossary Format

A glossary is a UTF-8 text file with one decoding-time injection entry per
line. The adapter converts this canonical form into a backend's free-text
context, hotword instruction, or CTC vocabulary. Post-processing string
replacement does not count as glossary application.

```text
# people
Example Name
Maccheroni

# terms
Qwen3-ASR
CoreAudio process tap
```

## Parsing Rules

1. The file must be UTF-8; reject invalid bytes and NUL. Permit a UTF-8 BOM but
   remove it from the first line.
2. Permit LF and CRLF line endings. Trim leading and trailing Unicode
   whitespace.
3. Ignore blank lines and lines whose first non-whitespace character is `#`.
   Treat an inline `#` as part of the entry.
4. Normalize entries to Unicode NFC. Preserve their original case and internal
   whitespace.
5. After NFC normalization, keep only the first of any exact duplicates.
   Preserve entries that differ only in case as distinct inputs.
6. An entry must contain at least 1 and at most 256 Unicode scalars. Control
   characters, including tabs, are not allowed.
7. File order is meaningful. When the backend has a limit, prioritize earlier
   entries. The adapter must not truncate silently; it records the number of
   applied entries and the reason for each exclusion.

There is no alias syntax. To recognize different forms of the same subject,
write each form on a separate line. Category comments are for human readers
and are not included in the backend payload.

If parsing produces zero entries, treat the file as no glossary. Comments and
blank lines may remain on disk so the editor can preserve its layout, but a run
or derived operation must record `provided: false`, a null glossary hash, zero
items, `injection_mode: none`, and `applied: false`. It must not claim that the
comment-only file reached a decoder or text post-processing backend.

## Hash and Manifest

Calculate `glossary.sha256` by applying SHA-256 to the input file's original
bytes, not the normalized entry list. This value proves which file was used.
`glossary.item_count` is the number of entries after parsing and duplicate
removal. `glossary.injection_mode` is one of the following:

- `free_text_context`
- `hotword_instruction`
- `ctc_vocabulary`
- `none`: used only for a control run that receives no glossary

`glossary.applied` is true only after the payload has actually been passed to
the backend call. It is false if the manifest merely contains the hash or if
only post-processing replacement occurred.

## Backend Conversion Rules

- free-text context: join entries with line breaks. Calculate the backend's
  length unit and limit before conversion; if the payload exceeds the limit,
  fail explicitly or record the excluded entries.
- hotword instruction: place entries in order into the backend's official
  instruction template. Record the instruction itself and the final payload
  hash in the run log.
- CTC vocabulary: pass each entry as one vocabulary element. Keep the language
  pin and boost settings in the profile and record them in the manifest.

The benchmark term recall denominator does not use this file directly. It
counts only the entries and occurrences spoken in the actual reference and
follows the normalization rules in `scoring.md`.
