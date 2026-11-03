# Skill 验证记录

验证对象为随包 `amd-fpga-embedded-dev-workflow/`，入口哈希、实际命令、运行环境、返回码及日志哈希见 [checks/results.json](checks/results.json)。本记录覆盖离线辅助功能与所选工程文件完整性。

| 项目 | 结果 | 原始证据 |
|---|---|---|
| 行为回归 | 79 项通过 | [regression.log](checks/regression.log) |
| 官方结构校验 | Skill is valid! | [official_structure.log](checks/official_structure.log) |
| 本地结构 | 21 Markdown、14 原子、49 处链接有效 | [structure.json](checks/structure.json) |
| 提交工程收包 | README 复现入口及工程类别齐全 | [received_project.log](checks/received_project.log) |
| 文件清单 | 76 文件、11838512 字节 | [selected_files.jsonl](checks/selected_files.jsonl) |
| 目录与同范围复核 | 所列文件匹配、两次清单无差异 | [verify_directory.log](checks/verify_directory.log)、[compare.log](checks/compare.log) |
| ZIP 成员 | 所列成员匹配、全部所选成员 CRC 通过 | [verify_zip.log](checks/verify_zip.log) |

行为回归包括输入快照及配置变更、目录新增/删除、工具版本解析、目录与 ZIP 接收、根 README 和嵌套工程、Skill 夹具排除、命令超时、清单中断、哈希篡改、选择范围和压缩成员核验。预期异常由测试断言检查；测试日志的通过表示对应处理符合契约。

文件核查选择 `src/`、`board/constraints/`、`board/burst_v7/` 和 Skill 核心目录，包含 RTL、模型、XDC、bitstream 及 DCP。临时 ZIP 用所列真实文件生成并读取核验，测试后清理；文件清单及执行日志保留。清单证明所选文件的一致性；完整依赖、逻辑功能、实现和模拟测量分别由源清单、工程回归、实现报告及实测材料判定。

## 可复查命令

从工程根目录执行，输出选择一个新的目录：

```powershell
py -3.13 -B build/scripts/validate_skill.py --out build/skill_check
```

该命令使用 Python 标准库，运行回归、链接核查、收包、清单生成、目录比较及 ZIP 成员检查。官方结构校验可另行指定本机 `quick_validate.py` 路径，并安装该校验器所需的 PyYAML：

```powershell
py -3.13 -B build/scripts/validate_skill.py --out build/skill_structure_check --structural-validator '<quick_validate.py path>'
```

本次实际离线运行环境为 CPython 3.12.13 / Windows；项目使用指南的 Python 3.13 是上位机与模型复现环境。辅助脚本使用 Python 3.10+ 标准库。日志中的绝对路径记录实际执行位置；复查命令按当前脚本位置定位工程。
