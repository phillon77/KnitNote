# Knit stitch sample review

Checked on 2026-09-15. Scope: one conventional, untwisted knit stitch with working yarn held in the **right hand** (English method). This audit verifies the named sample and its chosen geometry, not all possible teaching methods or national symbol conventions. Original teaching images are linked for reference; none are copied into the application.

## Sources and claims

| Source | Directly checked claim | Evidence and limits |
| --- | --- | --- |
| [Craft Yarn Council abbreviation list](https://www.craftyarncouncil.com/standards/knitting-abbreviations) | US abbreviation `k` means knit | Direct page opened; the list warns that a pattern can define its own abbreviations. |
| [CYC Learn Knit Stitch](https://craftyarncouncil.com/instructions_kn.php3) | First Knit Row: insert right needle from front to back; use right index finger to wrap below/over its point; pull through; slip the old loop | Direct page opened. Four operations paraphrased independently; garter fabric requires knitting every row and is not treated as another name for a single stitch. |
| [Nihon Vogue original publisher teaching](https://www.tezukuritown.com/nv/c/ckihonkb5/) | Japanese `表目`; working yarn behind, insertion from front, wrap/pull frontward, remove left needle, completed stitch | Text directly opened. Controller also visually inspected all four original teaching images and its single vertical stroke in a grid cell during this task. Symbol stored only with explicit right-side context. We do not infer its wrong-side instruction. |
| [Banul Academy original Korean curriculum](https://banulacademy.com/product/free_basic_course/) | Korean name `겉뜨기` is lesson 2 of foundational needle knitting | Direct web page and browser page opened; official teaching provider identified in footer. Registered-course videos are unavailable without enrollment. Original [Banul Story slow-motion lesson](https://www.youtube.com/watch?v=HvKEBU-eagA) was located but could not be fetched. Neither its needle direction nor a Korean glyph is claimed verified. |
| [Excelcraft / SO EASY original Chinese teaching](https://www.excelcraft.com.tw/teaching/8e2997c2.php) | `表目(下針)` | Direct page opened. `下针` is the simplified-character conversion of the confirmed Chinese name, rather than an independently sourced regional synonym. |

## Fixed learning names

| Language | Name | Evidence |
| --- | --- | --- |
| zh-Hant | 下針 | Excelcraft explicitly pairs this with 表目. |
| zh-Hans | 下针 | Orthographic conversion of 下針. |
| en | Knit | CYC abbreviation and teaching pages. |
| ja | 表目 | Nihon Vogue heading. `表編み` alias also appears in [Hamanaka original teaching](https://www.hamanaka.co.jp/kiso/omoteami.html), directly opened. |
| ko | 겉뜨기 | Banul Academy original lesson title; no Japanese-to-Korean inference. |

## Original vectors and continuity

All coordinates were authored for this application. Gray is the left needle; contrasting solid is the right needle; ochre dashed is the old loop; red solid is working yarn; teal thicker solid is the new loop; thin dashed paths give motion. Role differences include line width and dash, so color is not the sole indication. Needle polygons have pointed insertion ends. The drawing excludes hands and neighboring stitches to isolate the active loop; the lower red stem continues toward the omitted previously worked stitch, and the upper red stem continues toward the yarn supply. Both new-loop ends join these continuing strands exactly.

| Diagram | Required visible state | Adjacent-step continuity |
| --- | --- | --- |
| knit.step.1 | Right needle passes through the active old loop from the front; yarn stays behind | Old loop sits on the left needle at the same coordinates through steps 1–3. |
| knit.step.2 | Working yarn wraps the inserted right needle | Needles and old loop stay fixed; only the working yarn route changes. |
| knit.step.3 | Right needle brings a new loop through the old loop toward the viewer | Old loop remains on the left needle; new loop is highlighted separately from its continuing working strand. |
| knit.step.4 | Old loop leaves the left needle; the new loop remains on the right needle | Old loop settles beneath the new loop, its two legs remain at the same fabric attachment points; left needle is withdrawn. |

## Rendered inspection — 2026-09-15

Rendered the actual `StitchDiagramView` with macOS SwiftUI `ImageRenderer`, not a separately recreated drawing. The reproducible [renderer](previews/render-knit-preview.swift) and [light](previews/knit-steps-light.png) / [dark](previews/knit-steps-dark.png) PNGs are saved here.

- Step 1: pointed right needle enters the old loop; left needle overlays its crossing to indicate passage underneath, while the nearer right-needle shaft overlays the front strand. Working yarn remains behind the insertion point.
- Step 2: needle and old-loop positions stay fixed; the continuous working strand wraps the inserted point. Motion arrow is separate from the loop itself.
- Step 3: new loop appears at the emerging right-needle point, inside the old loop still held on the left needle; both teal endpoints join red yarn, including the lower continuation toward the previously worked stitch.
- Step 4: left needle is withdrawn; the old loop settles below the new loop on the right needle; old fabric attachment positions and both continuing yarn stems remain identifiable.
- Both appearances: needles, motion arrows, old/new loops and yarn remain visible; darker-mode yarn and loop colors were brightened after initial inspection. No drawing relies on translated text width.

**Sample status: verified for the stated schematic English-method operation and the fixed learning names.** This is a simplified sequence of needle/yarn states, not a photorealistic hand-position tutorial or evidence of every yarn-holding method. The Korean name is verified; no Korean glyph is supplied. Source-specific Japanese vertical-stroke glyph is restricted to the displayed right-side context. Automated coordinate and endpoint-connectivity checks support structural validity; they do not independently prove knitting technique correctness.
