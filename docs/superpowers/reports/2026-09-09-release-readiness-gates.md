# 1.7.0 (13) 發布準備驗收清單

2026-09-09 20:16 Asia/Taipei。狀態：既有證據與未完成門檻的彙整，不是新規格批准或實作計畫。

本輪實際核對 HEAD `1ca60ef2322e0bd024695b223d2654f23becff34`、branch `docs/cross-device-sync-design`。已完成代理皆 completed，沒有重新派工。ps 仍遭沙箱拒絕，沒有全機 compiler-idle 證據；本輪未啟動 compiler。保留既有未追蹤 `.superpowers/absent-source-design-progress.md`。

## 已完成 checkpoint 與證據範圍

同日 `2026-09-09-app-bootstrap-transport-bridge-verification.md` 與 `.superpowers/sdd/2026-09-09-app-bootstrap-transport-bridge/progress.md:94` 記錄六項 bridge 任務、整體審查及凍結驗證完成，後者記錄本機提交 1ca60ef。前者保留驗證當時尚未提交 Task6 的歷史描述，不應誤讀為目前 HEAD。

該候選的歷史驗證為 Core 2866/207、App 348/21、root 73/7，macOS build-for-testing 與 iOS build 成功，shipping bundles 為 1.7.0/13。這一輪僅讀取紀錄，沒有重新執行或延伸其驗證範圍。live CloudKit opt-in test 未執行；平台建置不是實機驗收。

## 未完成門檻與關閉所需證據

| 門檻 | 目前狀態 | 可接受的關閉證據 |
| --- | --- | --- |
| 舊本機資料接入 | 來源資格、持久接入證據與含糊來源政策待設計確認 | 明確批准的來源判定；完整備份與變更再驗證；取消、突然終止、同根重開、附件及待送資料保留測試；不以新 marker/UUID 冒充歷史歸屬 |
| bootstrap 前置 zone | fetch-first 提案，尚未實作 | 首次建立 admission 來源明確；隔離 driver 的 exact account/zone、結果、取消與 native drain 測試；既有 zone 不盲目 save，zoneNotFound 不等於可重建授權 |
| Watch 跨帳號 | 舊 wire 無 binding；新協定及相容策略待確認 | command/snapshot/ACK/handshake 全鏈綁定；混合版本、舊 pending、A→B→A、遲到訊息與離線重連測試；不得靜默清空或改綁舊指令 |
| 正式 composition 與狀態呈現 | 正常入口仍 local-only，bootstrap factory 未啟用 | 前述資料與協定門檻解決；單一 owner 的帳號事件接線及狀態/錯誤 UI 完整驗收；啟用候選的具體授權 |
| 真實雲端與設備 | 本輪未查驗或操作 | 明確測試帳號/容器/設備與資料範圍授權後，記錄同一候選多設備同步、離線、帳號切換、Watch、schema 與附件結果 |
| 發布候選與商店 | 本輪未查詢遠端或 App Store Connect，無推送/送審新證據 | 最終 SHA、版本/build、完整相關回歸、隱私及商店資料核對；簽署/export/推送/upload/送審分別取得具體授權並讀回結果 |

上述是六組門檻，不是「只剩六個操作」或工時估算。後續候選若改動，不沿用這次歷史測試數字冒充新候選已通過。

## 已有詳情，不重複研究

- 舊資料：`2026-09-09-sync-activation-gap-inventory.md`；包含四種既有 identity/source 入口的能力界線與備份/停止順序。
- zone：`2026-09-09-bootstrap-zone-provisioning-proposal.md`；以末段 19:27 fetch-first 收斂為準，先前 save-only 描述不是最終建議。普通 CKSyncEngine 已有 zone 管理，缺的是安裝前路徑。
- Watch：`2026-09-09-watch-account-boundary-inventory.md`；停止舊 coordinator 與驗證新實例收到的舊帳號指令是不同門檻。

## 下一個必要決定

先確認舊資料接入的產品安全策略：推薦來源歸屬無法證明時，保留原本本機使用與所有資料，不自動併入目前 iCloud 帳號；若要讓此類舊資料進入同步，另設明示的使用者確認匯入流程。這是待批准的產品選擇，不能假造 never-bound 證據，亦不能把使用者確認當成歷史歸屬認證。

相較直接依固定路徑自動接入，該方案較保守但需要額外流程；相較全面延期所有同步，能保留未來符合資格來源的接入路徑。批准方向後仍須完成精確架構規格與相容/復原設計，再取得規格確認，才進入實作計畫。

本輪只新增此清單，沒有 source/test 改動、編譯、提交、外部資料或發布操作。已批准切片完成；剩餘重要設計問題待使用者回答，排程應暫停而非重複相同盤點。

## 後續使用者決定：舊資料安全策略已同意

使用者對上述設計方向回覆「同意」：無法確認歸屬的舊資料保留本機，不自動併入目前 iCloud 帳號，另設明示確認匯入流程。這取代前節「方向待批准」狀態，但不代表完整規格、實作、Watch wire 或正式啟用已批准。

下一段待確認的匯入交易設計：確認畫面綁定當次已驗證目的帳號與來源版本；先完整備份、隔離準備及合併驗證，安裝前再驗證來源與帳號。帳號改變即撤銷確認；來源新增編輯需重新準備與確認，不能用舊快照覆蓋。取消或失敗保留原始資料及必要復原證據，重開先判斷交易狀態再決定恢復或回復，不盲目重複匯入。待送 Watch 指令與同步控制資料不得藉使用者確認改綁至新帳號。

本次僅記錄產品方向批准；架構設計依 brainstorming 逐段確認，尚未寫入實作計畫或程式。自動化本次未操作，不把「同意方向」當成新一輪排程啟用命令。
