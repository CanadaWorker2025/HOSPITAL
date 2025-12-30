# CorsixTH 问答要点汇总（本地 0.69.1）

## 配置与关卡覆盖
- 加载顺序：base_config.lua -> 00.SAM -> NN.SAM -> 若 map.lua 的 additional_config 包含该关，再叠加 Levels/originalNN.level。旧存档不会重载。
- originalNN.level 写法：#键路径 值，数组用 [索引]。示例：#towns[1].StartCash 80000，#expertise[40].StartPrice 1000。
- StartPrice：原版不会从 level_config.expertise[*].StartPrice 取价格，默认用疾病数据里的 disease.price。要让 .level 改价生效需改 hospital.lua 初始化病例簿逻辑。

## 诊断流程与覆盖
- GP 办公室也提供诊断进度，出房时用统一公式（疾病难度 MaxDiagDiff + 医生 skill/attention + 疲劳影响）。满技能且不疲劳的顾问 GP 可给约 0.7 进度，再经历任意一个诊断步骤+回 GP 基本可确诊。
- 每个疾病的 diagnosis_rooms 定义 GP 后可去的诊断房，例：baldness.lua 包含 x_ray、blood_machine、scanner。
- 最小“GP + 另一诊断步骤”覆盖集：建 general_diag、scanner、blood_machine。理由：大多数病含 general_diag；不含的（如 baldness/hairyitis/invisibility/king_complex/fractured_bones 等）都含 scanner；iron_lungs 等可用 blood_machine。
- 缺某诊断房时，列表只含该房的疾病会卡住（如 fractured_bones 只有 scanner）。

## 研究机制
- 产出：研究室研究员每日 1550 + 1000 * skill 点（Doctor:tickDay）；研究室物件加点：desk=100，computer=500，analyser=800（research.lua）。
- 分配：ResearchDepartment:addResearchPoints 将点数乘全局分配比例，再除以 gbv.ResearchPointsDivisor（默认 5，可在 .level 覆盖），再按各研究类别分摊（含 0.75–1.25 随机）。
- 提速：调低 gbv.ResearchPointsDivisor，或提高 research.lua 物件加点，或改医生 tickDay 公式。

## 员工幸福/疲劳与休息
- 幸福加减（Staff:tickDay）：工资公平度、疲劳超阈值、环境（附近植物/灭火器/垃圾桶/书柜/骷髅/电视各一次）、正在用的休息室物件（沙发/台球/游戏机）、房间 happiness_factor（窗户数与面积，Room:calculateHappinessFactor）。
- 同类型物件不叠加，取附近一件；不同类型可叠加。健康植物最高约 +0.002/天，枯死会减幸福。
- 休息判定（Staff:checkIfNeedRest）：疲劳 ≥ 政策阈值且房间可离开才去休息；被病人占用、在走路/排队/无休息室等会推迟。
- 暖气：只加热可达格子，墙会衰减。放房间主要加热房间，走廊需单独布置；室外草坪基本无效。

## 诊断房/流程参考
- 诊断进度统一由 Patient:completeDiagnosticStep 计算，Room:dealtWithPatient 中调用。无房间专属系数。
- 病房诊断 diag_ward 是病房的诊断步骤（非治疗）。

## 其他
- 细心程度 attention_to_detail：0~1 浮点，入职随机；默认培训/休息不提升，需改代码才会增长。
- 市场占有率：由声望和接待能力等决定，范围 0–100%。声望满但占有率低通常因竞争医院、接待/诊断瓶颈、收费过高、环境/温度差、死亡/送回家多。

## LSF mark
- 细心程度和能力，在休息室可以增长
- 10倍科研速度
- 10倍培训速度，细心和能力，都可以增长
- 空闲医生自动寻路，找空房间
- 灭火器，垃圾桶，增加happiness, 范围2->3, +0.002 per tick -> +0.1/tick
- config的地址 C:\Users\lvang\AppData\Roaming\CorsixTH
