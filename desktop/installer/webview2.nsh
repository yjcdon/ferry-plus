; Microsoft Evergreen Runtime product ID, independent of the Edge browser.
!define FERRY_WEBVIEW2_CLIENT "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

!macro customInstall
  IfSilent ferry_webview2_done
  Push $0

  ; On Windows x64 Microsoft stores the machine-wide version in the 32-bit view.
  SetRegView 32
  ReadRegStr $0 HKLM "${FERRY_WEBVIEW2_CLIENT}" "pv"
  SetRegView lastused
  StrCmp $0 "" ferry_webview2_user
  StrCmp $0 "0.0.0.0" ferry_webview2_user ferry_webview2_restore

  ferry_webview2_user:
    ReadRegStr $0 HKCU "${FERRY_WEBVIEW2_CLIENT}" "pv"
    StrCmp $0 "" ferry_webview2_missing
    StrCmp $0 "0.0.0.0" ferry_webview2_missing ferry_webview2_restore

  ferry_webview2_missing:
    MessageBox MB_YESNO|MB_ICONINFORMATION|MB_DEFBUTTON2 "Ferry Drive 已安装。网页登录网盘需要 Microsoft Edge WebView2 Evergreen Runtime。$\r$\n$\r$\n打开 Microsoft 下载页？该页面提供联网安装程序和 x64 独立安装程序。" IDNO ferry_webview2_restore
    ExecShell "open" "https://developer.microsoft.com/microsoft-edge/webview2/#download-section"

  ferry_webview2_restore:
    Pop $0
  ferry_webview2_done:
!macroend
