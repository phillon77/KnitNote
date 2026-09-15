# Offline stitch dictionary — content audit

Reviewed 2026-09-15. This audit covers the 15 bundled operations, their selected symbol variants, all authored learning names and 13-locale prose. It distinguishes an operation, a name and a publisher's glyph: evidence for one is not automatically evidence for the others.

## Scope and editorial status

- **15 operations**, in the approved order; **75 learning-name values** (`zh-Hant`, `zh-Hans`, `en`, `ja`, `ko`), with Traditional and Simplified Chinese stored independently.
- **46 original step diagrams**, **15 source-specific symbol diagrams**, **185 localization keys × 13 languages = 2,405 translated values**. The count includes controls, names, summaries, steps, accessibility descriptions, notes, legends, conditions and three `%lld` formats. None uses an English fallback as its translation.
- Each diagram's localized accessibility text describes the illustrated action. The shared localized legend explains needles, working yarn, old/new loops and motion. The source title is the publisher's proper title and is intentionally preserved.
- All translations were authored and checked for consistency of insertion direction, yarn position and stitch arithmetic. Japanese and Korean names without established exact terminology are visibly marked **説明訳 / 설명**. The Chinese advanced names are original explanatory learning labels, not a claim of a national standard.
- **Remaining editorial review:** no independent fluent Korean knitting editor has signed off on the newly authored Korean explanatory prose. Exact standardized Japanese/Korean aliases or glyphs are intentionally not asserted where sources only establish a family or result. A specialist terminology review remains an open content-release review item. Structural validation and this author review do not certify native fluency.
- Drawings describe conventional stitch mounting and right-hand yarn (English method), viewed by the knitter. “Front” is toward the knitter; “back” is away. Other hand positions and mounting conventions are outside this sequence.

## Operation-by-operation evidence and visual review

The `sourceIDs` in the JSON identify the precise source records and their claim limits. Counts are input stitches consumed → output stitches; the strand used for M1 and YO is not a consumed next stitch. Neighboring stitches visible in an M1 drawing are context only.

| Stable ID | Count | Operation and name evidence | Step image checks, final light and dark |
| --- | --- | --- | --- |
| knit | 1 → 1 | CYC knit lesson; Nihon Vogue 表目; Banul 겉뜨기; Excelcraft 下針, simplified 下针 | Four reviewed sample states retained: insert through old loop, wrap, draw toward viewer, release. Both ends of new loop join working yarn. |
| purl | 1 → 1 | Gosyo 裏目 teaches yarn front and backward draw; Banul 안뜨기 | Right needle approaches right-to-left toward viewer; yarn is in front, new loop emerges away. Released parent loop remains linked to new loop. |
| slip-knitwise | 1 → 1 | CYC `sl1k`; Japanese/Korean insertion descriptions are explicitly explanatory | Right needle enters as knit; old loop transfers with changed mounting. Yarn does not wrap; no green new loop appears. |
| slip-purlwise | 1 → 1 | CYC `sl1p`; Japanese/Korean descriptions are explicitly explanatory | Opposite insertion to knitwise; transferred old loop keeps its mounting. Working yarn stays behind in this example, independent of insertion direction. |
| yarn-over | 0 → 1 | Gosyo かけ目; Banul 바늘비우기; CYC YO | Yarn moves between tips to front, over right needle to back, leaves an open new loop. The untouched neighboring loop is visibly separate. Next knit is not counted as part of YO. |
| knit-front-back | 1 → 2 | CYC KFB/K1FB into front/back of same stitch; Banul 겉뜨기 코늘림; Japanese title is explanatory | First new loop made while parent stays left; back-loop insertion into same parent; two connected new loops after release. Parent was moved closer after first rendering to avoid a floating result. |
| make-one-left | 0 → 1 | Purl Soho Special Instructions gives front-to-back pickup/back-leg knit; Banul 왼코 늘리기-겉뜨기; Japanese description | Bar joins fixed neighboring fabric points; front-to-back pickup arrow, right needle behind for back-leg knitting; final bar twists under the new stitch. |
| make-one-right | 0 → 1 | Purl Soho gives back-to-front pickup/front-leg knit; Banul 오른코 늘리기-겉뜨기; Japanese description | Opposite pickup arrow and front-leg needle layer; final bar twist differs from M1L. It does not consume either neighboring stitch. |
| k2tog | 2 → 1 | CYC; Gosyo 左上2目一度 explicitly combines two into one; Banul K2TOG(코줄임) | Right needle enters two old loops together, one new loop emerges, both released old loops lead into the new stitch. |
| ssk | 2 → 1 | CYC plus Tin Can Knits classic two-knitwise method; Banul SSK(코줄임); Japanese description | Separate arrows show two individual transfers; left needle enters the fronts of **both** slipped loops, with right needle knitting through backs. Second-loop alignment corrected after visual review. |
| skp | 2 → 1 | CYC knitwise slip + knit + pass-over; Gosyo 右上2目一度 teaches the pass-over family; Korean description | One unworked held loop, then one newly knit loop; left needle visibly lifts the held loop over the new loop. Lifting needle corrected to reach the actual loop. |
| p2tog | 2 → 1 | CYC P2TOG; Japanese/Korean explanatory labels | Yarn front, purlwise insertion through two loops, new loop drawn away; released parent loops remain linked rather than floating below. |
| centered-double-decrease | 3 → 1 | CYC S2KP2 explicitly slips two **together as if k2tog**; Gosyo 中上3目一度 confirms center-top result; Korean description | One shared transfer arrow for two held loops, then knit remaining loop, then left needle lifts both together. This is not SSK's two separate transfers, nor SK2P. Last image shows the pass-over movement before old loops settle. |
| cable-left-two | 2 → 2 | Gosyo 右上1目交差 and CYC 1/1 LC both say hold first in front, knit next then held | Purple auxiliary needle is in the near/lower plane; held loop remains in front while other is knitted. Completion crosses first stitch above the other; deliberate gaps in the hidden strand show occlusion. |
| cable-right-two | 2 → 2 | Gosyo 左上1目交差 and CYC 1/1 RC both say hold first behind, knit next then held | Auxiliary needle is in the far/upper plane; held loop stays behind while other is knitted. Completion has the reverse over/under ordering, not just a relabeled LC drawing. |

**SSK and SKP are separate:** same usual slant does not establish identical operations. Gosyo's 右上2目一度 is not used as a bare alias for SSK. Japanese cable names identify the stitch lying on top, so Japanese 右上1目交差 maps to front-held English LC rather than a literal “right cable.” No exact Korean cable alias is inferred from the Korean PDF's directional labels.

## Primary sources directly opened or visually checked

| Source ID | Primary source | Evidence limits |
| --- | --- | --- |
| cyc-abbreviations | [Craft Yarn Council master list](https://www.craftyarncouncil.com/standards/knitting-abbreviations) | Opened during this task: international abbreviation identities and distinct operation definitions. US scope. |
| cyc-knit | [CYC First Knit Row](https://craftyarncouncil.com/instructions_kn.php3) | Previously opened and reviewed for the retained knit sample; hand/yarn and four-step operation. |
| nihon-vogue-symbols | [Nihon Vogue teaching](https://www.tezukuritown.com/nv/c/ckihonkb5/) | Controller opened page, visually inspected four original teaching images and vertical knit glyph. Retained source-specific right-side context. |
| excelcraft-basics | [Excelcraft / SO EASY](https://www.excelcraft.com.tw/teaching/8e2997c2.php) | Previously opened for sample: 表目 = 下針; 下针 is orthographic conversion. Not a source for every advanced Chinese name. |
| banul-basic | [Banul Academy basic curriculum](https://banulacademy.com/product/free_basic_course/) | Previously opened for sample: lesson title 겉뜨기 only; no enrolled video or glyph claimed. |
| banul-book | [Banul's original book listing](https://en.banul.co.kr/Mobile/Product/Detail/detail/pid/1221) | Reopened: Korean contents verify basic terms and KFB/M1L/M1R/K2TOG/SSK labels. Contents are not step or glyph evidence. |
| gosyo-purl | [Gosyo 裏目](https://www.gosyo.co.jp/kiso-movie-bou/5-12) | Reopened text: yarn front, backward draw, release. |
| gosyo-skp | [Gosyo 右上2目一度](https://www.gosyo.co.jp/kiso-movie-bou/5-15) | Reopened text: slip/knit/pass-over, two → one; CYC provides explicit knitwise qualification. |
| gosyo-k2tog | [Gosyo 左上2目一度](https://www.gosyo.co.jp/kiso-movie-bou/5-16) | Reopened text: two together → one. |
| gosyo-cdd | [Gosyo 中上3目一度](https://www.gosyo.co.jp/kiso-movie-bou/5-17) | Reopened text: two held together, knit next, pass both; center on top. CYC determines insertion. |
| gosyo-yo | [Gosyo かけ目](https://www.gosyo.co.jp/kiso-movie-bou/5-20) | Reopened knit-to-knit example; do not generalize yarn travel to every neighboring stitch. |
| gosyo-lc / gosyo-rc | [Gosyo front hold](https://www.gosyo.co.jp/kiso-movie-bou/5-22), [back hold](https://www.gosyo.co.jp/kiso-movie-bou/5-23) | Reopened: exact two-stitch front/back operation and Japanese names; their glyph geometry is not claimed inspected. |
| purlsoho-m1 | [Purl Soho special instructions](https://www.purlsoho.com/create/2022/01/18/lightweight-raglan-pullover-in-new-colors/) | Reopened exact M1 pickup and working-leg definitions; no garment instructions reproduced. |
| tincanknits-ssk | [Tin Can Knits classic SSK](https://blog.tincanknits.com/2013/10/03/ssk/) | Reopened original tutorial; two individual knitwise slips. No Japanese/Korean naming claim. |
| cyc-symbols | [CYC chart symbols](https://www.craftyarncouncil.com/standards/knit-chart-symbols) | Reopened table and personally inspected **12 linked original glyph images**, including both cable v1 examples. See chosen variants below. |
| knitter-academy-legend | [Knitter Academy](https://www.knitteracademy.kr/) / source PDF URL in JSON | Controller fetched public original PDF; implementer personally inspected rendered PDF page 4 (printed page 2). Only vertical knit and horizontal purl facts selected. Not a general wrong-side rule. |

The Purl Soho KFB tutorial re-fetch returned 403 during this task. It was not used to claim fresh verification; CYC's same-stitch front/back definition and the previously documented original tutorial research provide the operation context. No failed URL, search snippet, unavailable course, paid pattern or unverifiable Korean dictionary page was treated as verified content.

## Symbol variants and face conditions

- **Japanese sample:** Nihon Vogue vertical stroke = knit viewed from right side. No wrong-side rule inferred from that sample.
- **Korean source:** source-specific vertical stroke = 겉뜨기; horizontal stroke = 안뜨기. The source also permits an empty cell for purl, but that empty variant is not supplied as an invisible graphic. Its conditions explicitly say this source alone and no inferred universal wrong-side rule.
- **CYC first variants, personally compared to source images:** purl horizontal bar; YO circle; KFB vertical with upper-left branch; M1L/M1R direction-specific branched diagonals; k2tog/SSK direction-specific branched diagonals; p2tog branched diagonal with short bar below; purlwise slip V with underline; CDD central vertical with two lower branches; 1/1 LC and RC version-1 crossing ribbons. These are independent vector constructions of symbol facts, not copied/traced pixels or original grid images.
- CYC face mapping is explicit in localized conditions: p ↔ k; kfb ↔ pfb; k2tog ↔ p2tog; SSK ↔ SSP; p2tog ↔ k2tog; S2KP2 ↔ SSPP2. Purlwise slip variant: yarn behind on right side, yarn in front on wrong side. International abbreviations in conditions stay intact across languages.
- No distinct **knitwise-slip** or **SKP** glyph was verified, so those entries have empty `symbols`; the localized no-verified-symbol message is supplied. Do not substitute the SSK glyph for SKP.
- All publishing conventions remain subordinate to the user's own pattern key. Source cards must remain separate even where two sources happen to share geometry.

## Original drawings and inspection evidence

All product vectors were authored for this application. Hands, fabric away from the active stitches and some depth are omitted. Needles have pointed insertion ends. Red continuing yarn meets both endpoints of each teal new loop exactly; the lower continuation goes toward previously worked fabric and the upper continuation toward the yarn supply. Dashed old-loop strands are not new yarn. Small gaps in a cable's farther strand indicate occlusion by the nearer strand, not cut yarn.

The actual app `StitchDiagramView` was rendered with SwiftUI `ImageRenderer` using [render-dictionary-preview.swift](previews/render-dictionary-preview.swift). Final PNGs are in [previews/full](previews/full): one light and dark sheet for every operation and a light/dark symbol sheet (**32 inspected images**). These are author review artifacts, not shipped raster resources; the App uses only JSON vectors.

First render found detached released-parent loops, an SSK needle missing the second loop, an idle needle not reaching a pass-over loop, and indistinguishable cable depth at the final crossing. All were adjusted and re-rendered. All final light/dark states and symbol sheets were personally inspected. Motion/old-loop dash patterns and different widths supplement color; brightened dark-mode yarn and auxiliary needle stay visible. The existing knit geometry was retained.

## Automated verification and limits

- `python3 scripts/validate_stitch_dictionary.py --self-test`: real 15-entry order, names, sources, related IDs, unique diagram/symbol IDs, valid command coordinates, recursive `*Key` and `noteKeys` inventory, complete nonblank `translated` values in all 13 languages, matching ABI format types, required `%lld` count formats.
- Small fixture tests execute the same CLI. Valid fixture returns 0; deleted Korean step, `%@` replacing `%lld`, broken diagram ID, blank translation and out-of-range coordinate each return 1 with the specific failure.
- Focused Swift tests verify 15 distinct operations/counts, independent step references, source-tagged Korean examples, cable-needle availability, no new loop for slips, exact joining of new-loop ends to continuing yarn, and proximity of new loops to parent fabric. The proximity check intentionally does not assert exact drawing snapshots and does not prove 3D topology.
- Existing non-dictionary localization entries are unchanged. No third-party images, source PDFs, pattern charts, garment instructions, data migrations or runtime network fetches are included.
