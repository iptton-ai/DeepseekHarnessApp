# wire/ — 契约防火墙(ADR-0001)

**只读层。** 本包所有 wire 形状知识都活在 `generated/`(codegen 产物)与 `tool/codegen/`(生成器)里。

## 不变式
- 禁止手写任何 wire 模型;全部来自 `tool/codegen`(zod schema → JSON Schema → Dart)
- 再生成:`node tool/codegen/export-schemas.mjs && dart run tool/codegen/generate_dart.dart`
- 生成器钉死 dsh 版本(`dshVersion` 常量 vs manifest);不匹配直接 exit 2
- 入口只有一个:`import 'package:singleman/wire/generated/wire_generated.dart';`
- envelope 两级解析纪律:先 `RpcMessage.fromJson`(四象限信封),业务值再按方法二次 parse

## 上下文清单(做 wire 任务前读什么)
- `generated/wire_generated.dart` 头部 + `RpcMethods`(全部 52 方法名)
- `test/conformance/live_host_test.dart`(信封纪律的活样板)
- `docs/DSH-PROTOCOL.md` §1(四象限)、§4(帧联合)

## 已知妥协
- zod v4 toJSONSchema 把所有复用 inline;生成器靠结构去重还原命名类(相同 JSON 形状 → 同一个类)
- 无判别器的 union(如 imageMediaType 的 const-anyOf)退化为 `dynamic` typedef
- branded id(RpcId/SessionId…)是 typedef 别名,不是独立类型
