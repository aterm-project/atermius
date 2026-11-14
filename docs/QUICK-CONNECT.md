# 首页搜索和快捷连接

本地与账户主页在输入时实时筛选主机，操作、协议筛选和分组选项位于搜索框下方。输入连接命令后可按回车或点击连接提示：

| 输入 | 行为 |
| --- | --- |
| `ssh root@example.com -p 22122` | SSH 连接指定用户名和端口 |
| `rdp admin@192.0.2.10` | RDP，默认 3389 |
| `rdp DOMAIN\user@host -p 3390` | RDP 域用户名与自定义端口 |
| `vnc 192.0.2.10:5901` | VNC，未指定端口时为 5900 |
| `ssh user@[2001:db8::1] -p 22` | IPv6 地址 |
| `console` | 桌面端本机 Shell |
| `console tty @COM3` | Windows COM3 串口，115200 baud、8N1 |
| `console tty @COM12 -b 9600` | Windows 串口与自定义波特率 |
| `console tty @/dev/cu.usbserial-0001` | macOS 串口设备 |
| `console tty @usb:0403:6001 -b 9600` | Android：USB 转串口适配器（厂商:产品 ID） |
| `console tty @usb:0403:6001:A50285BI` | Android：按 USB 序列号指定适配器 |

串口也接受 `tty @COM3` 和 `console @COM3`。COM 端口适用于 Windows，`/dev/cu.*` 适用于 macOS，`usb:` 端口仅适用于 Android；Web 不启动本机 Console，也不会将这些文本作为服务器端 Shell 命令执行。

匹配已保存主机时，协议、地址、端口和显式用户名必须一致，才复用该主机的凭据。多个匹配项会让用户选择。新地址打开右侧凭据编辑器，预填协议、地址、用户名和端口，点击“保存并连接”后随主机加密保存登录信息并发起连接。取消不会建立连接。

命令解析器只接受连接参数，不调用 Shell，不支持 `-o`、代理命令、管道或附加远程命令。普通文本继续作为名称、地址、用户名或标签搜索。Windows 串口使用系统通信 API，8 数据位、无校验、1 停止位、无流控；输入队列限制为 64 KiB，读取不阻塞界面，写入带超时，标签关闭会释放设备。波特率范围为 50–4000000，具体值仍须设备驱动支持。

## Android USB 串口

Android 没有本机 Shell，但可以通过 USB OTG 线或转接头连接 USB 转串口适配器使用串口 Console。支持的芯片家族：USB CDC-ACM（Arduino、STM32 虚拟串口等）、FTDI（FT232R、FT2232/FT4232 等）、Silicon Labs CP210x、WCH CH340/CH341 和 Prolific PL2303。设备必须支持 USB 主机（OTG）。

在主页选择 **添加 → 串口 Console…**：对话框列出已连接的适配器（可点“刷新”），选中一个端口并填写波特率后点“打开 Console”。此时 Android 会针对这一个适配器弹出系统 USB 访问确认；应用不会在插入设备时自动启动，也不会为未选中的设备请求权限。访问权限由 Android 管理，拔出后需要重新允许，应用不保存它。

端口标识为 `usb:厂商ID:产品ID[:序列号][#端口号]`，ID 为 4 位十六进制，`#端口号` 只用于多端口适配器（第二个端口为 `#1`）。Android 10 起只有获准访问后才能读到序列号，所以对话框在允许后再生成带序列号的标识；序列号让重新插拔或同时接入的多个同型号适配器仍能被正确区分。没有序列号的标识只在恰好接入一个同型号适配器时才会打开；接入多个同型号、无序列号的适配器时会提示从对话框重新选择。复制、分屏和窗口组合沿用同一标识和波特率；设备未接入、换成其他适配器或拒绝访问时，标签页显示原因，可从对话框重新选择端口。

Android 串口同样为 8N1、无流控，打开后置高 DTR/RTS（多数串口控制台需要）；输入队列与未读输出各限制为 64 KiB，写入 2 秒无进展即超时并结束会话；拔出适配器会结束会话并显示“USB 串口适配器已断开连接”；关闭标签页或应用会释放设备。驱动来自随源码提供的 [usb-serial-for-android](https://github.com/mik3y/usb-serial-for-android) 3.11.0（MIT，见 `apps/client/android/usbserial/UPSTREAM.md`），构建时不访问网络。当前只完成了编译和单元测试，尚未用实体 USB 串口适配器做收发验收。

## Windows 串口实现依据

串口实现依据微软 [COMMTIMEOUTS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-commtimeouts)、[DCB](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-dcb) 和 [SetCommState](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setcommstate)。当前 Windows 探针验证不存在端口的可见错误和正常清理；没有实体串口收发验收。
