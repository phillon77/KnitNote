# PhoneWatchSession 本機生命週期停止與收尾

日期：2026-09-07。狀態：使用者已確認；本機子計畫已實作、審查及固定候選驗證完成。證據見 `docs/superpowers/reports/2026-09-07-native-watch-session-stop-verification.md`，不代表完整同步或發布驗收。

基準：`b4c556b04b289ba5147ab198a5da35477c79c25d`。先前 producer-stop 子計畫已完成；其固定候選 `4710efc96fa70b9f8705b04c6141182b0519714d` 的完整 Core 2520/186、本機測試 34/3 及未簽署 macOS/iOS 建置結果只屬既有基準，不沿用為本段驗收。

## 目的與既有缺口

使用者已確認下一步補齊 Watch 底層停止、拒絕遲到工作及等待已接受工作。本段細化該意圖：讓 `PhoneWatchSession` 本身能提供本機 stop/drain，供後續 App session owner 組裝，不直接啟用帳號切換或真實雲端。

目前 `PhoneWatchSession.swift` 的 `sessionDidDeactivate` 會建立 MainActor Task，通知 callback 後自行 `WCSession.activate()`；收件 FIFO 在 callback 為 nil 時仍可能回空字典；已排隊的傳送完成回呼也由 adapter 自己建立 Task。停止 `PhoneWatchSyncCoordinator` 無法關閉或等待這些 adapter-owned 工作。

## 方案選擇

採用同一個真實 `PhoneWatchSession` 的平台中性生命週期邏輯，將 WCSession 專用實作與 delegate 薄層保留在 `#if os(iOS)`。隔離測試直接編譯同一份 App 來源，以 native operations 替身取代系統呼叫。

- 不採只清除 coordinator callback：不能阻止 adapter 自主重新啟動或 FIFO 回覆。
- 不採新增 App-host 測試來驅動真實 WCSession：會擴大到系統 factory／配對服務，超出這次隔離測試範圍。
- 不複製 adapter 到測試環境、不用另一個假生命週期實作證明正式 adapter。

代價是微調內部 native operations 介面及條件編譯位置；對外 Watch wire、現有正常單帳號行為、iOS App 的 `PhoneWatchSession()` 呼叫方式不變。macOS App 不建構 live Watch adapter。

## 固定範圍

- 版本維持 1.7.0 (13)，iOS 18、macOS 15、watchOS 11。
- 不改資料／備份／同步／Watch wire 格式、購買授權、語言、開發故事、100,000,000-byte 與 64 MiB 上限。
- 不修改 Watch 端 `KnitNoteWatch/Sync/WatchSession.swift` 的行為。
- 不改綁 store、不新增資料清理／inventory／seal 權威，不操作正式資料。
- 不新增 shipping target；不啟動 App host、真實 WCSession、CloudKit、Keychain 或 StoreKit。
- 本段不接入 App owner、UI generation 或 CloudAccountDomainLifecycle；不對已送出的 OS 傳輸作撤回／清空保證。

## 介面與檔案責任

`KnitNote/WatchSync/PhoneWatchSession.swift` 保留 adapter 與 iOS delegate 薄層，新增 `AppSessionProducer` conformance；使用既有 `AppSessionCallbackGate`，不另造平行追蹤機制。

`WatchConnectivitySessionOperations` 改為 MainActor 的平台中性內部介面，保留 reachability、activate、application context、sendMessage、enqueueUserInfo，將 WCSessionDelegate 型別的 property 改成下列 owner 操作：

```swift
func installDelegate(_ owner: PhoneWatchSession)
func removeDelegate(ifOwnedBy owner: PhoneWatchSession)
```

iOS 的 `WCSession` conformance 實作 delegate 設定；移除時只有 `delegate` 仍為同一 owner 才設 nil，不能讓已停止 A 拔掉 B 的 delegate。測試替身同樣使用 owner identity。

平台中性 initializer 必填 operations 與 `isSupported` closure。只在 iOS 提供維持原呼叫方式的零參數 convenience initializer，以 WCSession.default 組裝；隔離測試不得呼叫此 convenience initializer。

iOS delegate 方法只擷取必要值並同步轉交 adapter 的平台中性入口，包括啟動結果、失效／停用、reachability、四種原始收件及 user-info 完成。不得在薄層另建未追蹤 Task。平台中性入口由真實 adapter 持有，供測試直接驅動同一套處理邏輯。

新增 `Tests/KnitNoteAppTests/PhoneWatchNativeSessionLifecycleTests.swift`，只在需要時新增專用 fixture 檔。以新計畫自己的 actual-source no-host harness symlink 所需 Core/App/test 來源；既有完成計畫的 SDD workspace 不重開、不重做。

## 同步停止

`stopForSessionTransition()` 是 MainActor、同步、不可逆、可重複呼叫：

1. 先設定 stopped 並關閉 callback admission gate；在任何外部 callout 前完成。
2. 清除 adapter 的四個 coordinator callback。
3. 透過 operations 移除仍由自己持有的 delegate。若 native delegate 已屬 B，不移除 B。
4. 不啟動 native session、不傳送新訊息，不呼叫舊的 reply/failure callback。

停止後 `isReachable` 回 false，不向 native operations 查詢。activate、sendMessage、transferUserInfo 為無副作用拒絕；throwing updateApplicationContext 拋明確的 stopped error。對外錯誤型別限 App adapter 層，不改 Core wire。

所有 native operations 與使用者 callback 都可能同步重入 stop。呼叫 installDelegate、isSupported、onActivationCompleted 等之後，如仍要執行 activate/send/reply 等後續動作，必須再次確認未停止。已在 stop 之前開始的 native 同步呼叫無法撤回，不能將其誤標成停止後的新呼叫。

## 回呼與 FIFO 的工作所有權

每個 native callback 在建立 MainActor Task **之前**，透過 adapter 私有 gate 登記。停止後拒絕新登記；先前接受的 Task 保留 gate 到最後的 defer finish。不要讓未登記的 delegate Task 在 drain 返回後才到達 MainActor。

一般 delegate 通知、原始 FIFO drain，以及 outgoing message 的 reply/error 到達都遵守此規則。已在 native framework 保留、但於 stop 之後才到達的 closure 直接拒絕，不建立 Task、不發布結果。登記的是已到達且被本機接受的工作，不是在 sendMessage 開始時登記一筆永遠等待遠端答覆的工作。

沿用 `WatchConnectivityReceiveFIFO` 的單一 drain 與順序。原始收件先登記再 enqueue；若已有 drain，該 enqueue 的登記在同步入列結束後完成，由既有 drain 保護處理；新 drain 的登記則保留到整個 Task 結束。所有 enqueue／最後 dequeue 的競爭仍由 FIFO 自己的鎖序列化，沒有跨 await 同步鎖。

停止後已接受的 FIFO 工作仍會消耗／放棄排隊資料以完成本機收尾，但不能解碼後傳給 coordinator，亦不能呼叫 replyBox.fail() 回覆。停止後才到達的新收件不入列。傳給 coordinator 並可能被保留的 reply closure 也必須在實際使用時檢查 adapter stopped；不能因早先取得 closure 就跨過停止邊界。

未停止的正常路徑保留收件順序、有效 reply、無效 envelope 的一次性 failure，以及 reply/error 競爭只完成一次的行為。可沿用既有 ReplyHandlerBox、SendableDictionary、MessageCompletion，不改它們的 wire 編碼。

## 等待契約

`waitForStoppedOperations()` 在未停止時拋既有 `AppSessionProducerDrainError.producerStillActive`；停止後等待私有 gate 已接受的本機工作完成。取消某個等待者不能取消共用工作或讓另一個等待者提前成功。只有成功 return 才是本機收尾證據；CancellationError／其他錯誤不是清理授權。

成功不代表 WCSession 網路／OS transfer 終止、framework 釋放所有 closure、Watch 遠端清空或帳號 wire 驗收。等待不應依賴可能永不返回的外部 reply。新的 session 必須使用新的 adapter 實例。

測試若需觀察登記與收尾，可使用既有 gate 的不可變 State 觀察 callback，由 adapter 自己建立全新私有 gate；不可注入可變 gate、Task list 或新權威。

## 驗證矩陣

1. 正常基準：native activate/delegate、reachability、有效及無效 FIFO、消息 reply/error 一次性語意保持。
2. 同一 MainActor 同步區段入列 callback 後立即 stop：drain 等待已接受工作，無遲到 activation、通知、傳送或 reply。用實際登記／終結觀察，不用 empty Task fence、sleep、yield 或時限斷言。
3. 原生失效回呼已排隊但尚未跳到 MainActor 時停止，以及 onActivationCompleted 同步重入 stop：不得再次 activate。
4. 四種原始收件共用 FIFO，stop 前保持順序；stop 後有效、無效及先前保留的 reply closure 都不回覆。
5. outgoing message 的 native reply/error 在 stop 前後與同時競爭；stop 後不發布結果，stop 前維持一次性完成。
6. stopped API、重複 stop、open wait、兩個等待者、取消一個等待者與晚到回呼均涵蓋。
7. native endpoint 已改由 B 持有時，A stop 不清除 B delegate；A 關閉不能關閉 B 的 gate，B 仍能正常處理。
8. 所有測試錯誤及取消路徑先釋放、獨立成功 join 自有工作，再清理資源。刻意破壞的 RED 不得依賴已破壞的 drain 證明安全清理。
9. App 來源以 symlink 編譯；測試 operations 不呼叫任何 live factory。iOS 薄層實際來源與 forwarding 在獨立審查及未簽署 iOS 建置中驗證，這不冒充真實 WCSession 執行。
10. 每項新增行為先有可重現 RED 再 GREEN；相關 Core／native adapter 本機測試通過後獨立審查，再固定候選跑完整 Core、完整本機 harness、未簽署 macOS/iOS 建置。舊結果不當新候選驗收。

## 完成與後續

本段完成只代表 adapter 可被未來 owner 停止及收尾。接著才組裝 App session/generation、舊畫面隱藏、store／producer／adapter 的固定所有權與帳號切換順序。真實 CloudKit、實機、Watch 帳號歸屬協定、購買／本地化及精確發布候選仍分開驗收。

保留本機分支與證據；不重新啟動已暫停的夜間自動化，不合併、推送、簽署、安裝、上傳、送審或清理正式資料。

設計自查：所有 Task 有同一 admission/drain 所有權；FIFO 不更改 wire；停止與同步重入明確；A 不能移除 B delegate；外部未回覆傳輸不阻塞本機 drain；平台測試與實機證據不混用。使用者確認後已完成分步實作計畫及本機驗證，詳見上述報告。
