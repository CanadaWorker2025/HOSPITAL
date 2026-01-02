# HOSPITAL LOG

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
- 细心程度 attention_to_detail：0~1 浮点，入职随机；默认培训/休息不提升，改代码才会增长。
- 市场占有率：由声望和接待能力等决定，范围 0–100%。声望满但占有率低通常因竞争医院、接待/诊断瓶颈、收费过高、环境/温度差、死亡/送回家多。逻辑与修改：
  - 文件：`CorsixTH/Lua/world.lua`
  - 改动：`getReputationImpact` 分母从 `250` 改为 `(500 / 3)`，公式为 `1 + ((reputation - 500) / (500 / 3))`。
  - 效果：声望 500 → 系数 1（维持 25% 基础占比），声望 1000 → 系数 4，对应基础 0.25 * 4 = 1.0，可达 100% 占有率；声望低于 500 仍有 0.01 最小值。
  - 冲突与风险：未引入新字段/存档破坏；患者生成量随声望上升更快，尤其 600+ 后更陡，需关注高声望时病人过多的问题。如要封顶可在 `onEndMonth` 对 population 取 `math.min(population, 1)` 或调低 `base_config.popn` 的 `Change`。


## Function 实现/变更记录
### 空闲医生自动寻路，找空房间
- 主要修改文件：CorsixTH/Lua/calls_dispatcher.lua（新增自动补位调度）、CorsixTH/Lua/room.lua（职工进入房间时清除补位标记）。
- 新增/改动的函数与字段：
  - autoFillIdleRooms：每 50 tick 执行；清理过期补位分配，收集空房与走廊闲职工，按最近距离指派；每轮最多 3 个指派限流；轮询房间起点，避免后面房间长时间饿死；覆盖诊断、treatment、clinics 三类房。
  - shouldAutoFillRoom：判断房间缺人且类型匹配（诊断/治疗/clinics），且无有效补位占用。
  - isAutoFillCandidate：仅走廊闲医生/护士（非手艺人/接待，未 on_call/未被拾起/不在房间）。
  - clearAutoFillForStaff：当职工接到正式呼叫或进入房间时清理补位状态，避免占坑。
  - 数据字段：auto_fill_rooms（房间→补位职工）、_auto_fill_cooldown（节奏控制）、_auto_fill_room_cursor（房间扫描轮换）。
- 逻辑效果：空房每 ~2.5s 自动抓最近的走廊闲职工补位；路径不可达则跳过继续找；诊断/治疗/诊所类房间均可被补位；正式紧急呼叫会覆盖补位并清理标记。
- 遇到的问题与解决：
  - 旧存档缺失 _auto_fill_cooldown、auto_fill_rooms 报错：在 onTick/autoFillIdleRooms 中默认初始化。
  - CPU 卡顿：补位每轮最多 3 个指派并分摊房间轮询。
  - 诊所类房间（如 DNA Fixer）无人补位：shouldAutoFillRoom 增加 categories.clinics 支持。
  - 补位占坑：进入房间或接到正式呼叫时调用 clearAutoFillForStaff 释放。
- 后续风险/待观察：补位职工若被阻挡但仍保持闲，可能长时间持有 auto_fill_room；目前轮询清理 fired/dead/on_call/pickup/在房间/非闲/医院不符，如出现“走廊站桩不进房”可再加“未朝目标移动超时”清理；多空房场景需多轮覆盖，可按表现调节限流或间隔。

### 员工在休息室增长细心程度和能力
- 主要修改文件：CorsixTH/Lua/humanoid_actions/use_staffroom.lua
- 细心/能力成长（休息室）：CorsixTH/Lua/humanoid_actions/use_staffroom.lua 中 UseStaffRoomAction 的休息循环 loop_callback_use 会在休息室使用物件时，每 tick 小幅提升 profile.attention_to_detail（+relaxation*0.5，封顶 1）和 profile.skill（+relaxation*1.5，封顶 1，并调用 parseSkillLevel）。仅对有 profile 的职工生效，随使用沙发/台球/游戏机累积；离开房间、正常疲劳恢复逻辑保持不变。

### 员工在培训室增长细心程度和能力
- 主要修改文件：CorsixTH/Lua/entities/humanoids/staff/doctor.lua
- 细心/能力成长（培训室）：CorsixTH/Lua/entities/humanoids/staff/doctor.lua 中 Doctor:tick/Doctor:trainSkill 在培训室、讲台椅学习时根据 TrainingRoom 的 training_factor、人数、阈值计算 delta 提升 profile.skill/专科标记，并在通用技能训练时额外提升 attention_to_detail（+delta*1.5，封顶 1）。房间因子由 CorsixTH/Lua/rooms/training.lua 根据投影仪、骷髅、书柜和 TrainingRate 构成；人数越多增长越慢；满值触发晋升/专科提示与头衔更新。


## Config Change LSF mark 
- 细心程度和能力，在休息室可以增长
- 10倍科研速度
- 10倍培训速度，细心和能力，都可以增长
- 空闲医生自动寻路，找空房间
- 灭火器，垃圾桶，增加happiness, 范围2->3, +0.002 per tick -> +0.1/tick
- config的地址 C:\Users\lvang\AppData\Roaming\CorsixTH
