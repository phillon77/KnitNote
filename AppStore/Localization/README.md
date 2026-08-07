# KnitNote terminology glossary

`KnittingTerminology.csv` is the human-reviewed terminology source of truth for KnitNote 1.4.1 translators and String Catalog reviews. Each row expresses one semantic meaning across English, Traditional Chinese, Simplified Chinese, German, French, Japanese, Norwegian Bokmål, Swedish, Finnish, Danish, Korean, and modern Greek. Native-speaker release sign-off is still required; the table and automated checks do not replace it.

English defines a row's semantic intent. Simplified Chinese starts with a Traditional Chinese conversion only as a drafting aid, then is rewritten and reviewed for natural Mainland knitting usage; it must never be treated as character-for-character conversion.

The glossary is documentation and test input only. KnitNote continues to load runtime UI strings exclusively from its Apple String Catalogs. It does not translate, rewrite, or otherwise alter user-created or imported content.

`catalogKeys` binds each row to runtime catalog content. `*` governs every runtime key whose English string or variation contains one of the row's approved English terms. Separate narrower explicit keys with `;`; a trailing `.*` filters that English-term match to one semantic key family. Use `-` only when the English term is absent from the runtime catalog. Separate approved inflections or context-dependent variants within a language cell with `|`; suffix a reviewed inflection stem with `*`. Every governed runtime string and variation must match one approved term or stem.

When adding a row, use a stable semantic key, provide a non-empty value in every required language, and avoid duplicating a spelling for a different meaning. Keep the same term family for the same meaning across all governed UI surfaces. Update `catalogKeys` and the approved variants with the runtime String Catalog change so `KnittingTerminologyContractTests` can reject drift.
