# sessions/ — 会话领域状态(M2)

## SessionStore(已实现,域层)
- 代际 ready → 全量重取 session.list(**无 since 续传**;已积累日志靠 seq 去重保留)
- loadHistory:尾页(beforeSeq 缺席)→ hasMore 向前翻页;projections 水位快照(asOfSeq)落格
- mux session/event 按 seq 去重、有序插入(重连重放安全)
- session/projection 高 seq 覆盖;host/session-status 折叠 running
- promptText:mode:queue 纯文本块

## 不变式
- 事件日志只增不改;seq 是唯一排序/去重键
- 投影覆盖只看 seq 水位,与帧/响应到达顺序无关(乱序天然安全)
- 上层只消费广播流(summaries / log.eventStream),不碰 wire

## 待做(M2 后半)
- workspace.list + session.create 入口
- UI:会话列表 + 消息流渲染(纯文本先行,markdown 后补)
- 验收:桌面 app 一次真实对话 + 拔线重连不丢状态
