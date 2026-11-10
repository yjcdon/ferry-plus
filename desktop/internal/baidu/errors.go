package baidu

import (
	"errors"
	"fmt"
)

var (
	// ErrDirectoryCreationRejected means the server explicitly refused mkdir.
	ErrDirectoryCreationRejected = errors.New("百度未创建目录。")
	ErrMissingBDUSS              = errors.New("请重新复制百度网盘主页的完整 Cookie 后登录。")
	ErrMissingSTOKEN             = errors.New("请重新复制百度网盘主页的完整 Cookie 后登录。")
	ErrLoginExpired              = errors.New("登录已失效，请重新复制网盘的 Cookie 登录。")
	ErrLoginStateMissing         = errors.New("请重新登录百度网盘后打开分享。")
	ErrSecurityVerification      = errors.New("百度要求账号安全验证，请先在浏览器中登录网盘完成验证。")
	ErrInvalidShareLink          = errors.New("请输入百度网盘分享链接。")
	ErrInvalidPassword           = errors.New("提取码应为 4 位字母或数字。")
	ErrPasswordRequired          = errors.New("这个分享需要提取码。")
	ErrWrongPassword             = errors.New("提取码错误。")
	ErrWrongOrExpiredPassword    = errors.New("提取码错误或已失效，请重新打开分享。")
	ErrShareNotFound             = errors.New("分享页面不存在，请检查链接是否完整。")
	ErrShareExpired              = errors.New("分享已失效，可能已被取消、删除或过期。")
	ErrShareUnavailable          = errors.New("分享不存在或已失效。")
	ErrShareBanned               = errors.New("这个分享因违规被禁用。")
	ErrCaptchaRequired           = errors.New("百度要求输入验证码。请稍后再试，或先在浏览器中打开这个分享。")
	ErrVerificationTriggered     = errors.New("触发了百度的人机验证，请稍后再试，或先在浏览器中打开这个分享完成验证。")
	ErrFileNotFound              = errors.New("网盘中找不到这个文件或目录。")
	ErrAlreadyExists             = errors.New("已存在同名的文件或目录。")
	ErrInvalidFileName           = errors.New("文件名不合法。")
	ErrInvalidNameOrAccessDenied = errors.New("请检查文件名称和访问权限。")
	ErrAccessDenied              = errors.New("无权访问这个文件。")
	ErrUnauthorized              = errors.New("百度拒绝了请求（user is not authorized），请稍后再试。")
	ErrNoDownloadLink            = errors.New("下载链接获取失败，请重试。")
	ErrTooManyItems              = errors.New("一次操作的文件太多。")
	ErrTryLater                  = errors.New("百度服务繁忙，请稍后再试。")
	ErrInvalidResponse           = errors.New("百度服务响应异常，请稍后重试。")
)

type HTTPError int

func (e HTTPError) Error() string { return fmt.Sprintf("服务器返回 HTTP %d。", e) }

type APIError struct {
	Code    int64
	Message string
}

func (e APIError) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("百度返回错误（错误码 %d）：%s", e.Code, e.Message)
	}
	return fmt.Sprintf("百度返回错误（错误码 %d）。", e.Code)
}

func apiError(code int64, message, op string) error {
	switch {
	case code == -12 || code == -9 && op == "verify":
		return ErrWrongPassword
	case code == -9 && op == "shareList":
		return ErrWrongOrExpiredPassword
	case code == -62 || code == -19:
		return ErrCaptchaRequired
	case code == 8001 || code == 9019:
		return ErrVerificationTriggered
	case code == -7 && (op == "verify" || op == "shareList") || code == -21 || code == 105:
		return ErrShareExpired
	case code == -7:
		return ErrInvalidNameOrAccessDenied
	case code == -1:
		return ErrShareBanned
	}
	switch code {
	case -6, -4, 3, 31041, 31042, 31045:
		return ErrLoginExpired
	case 132:
		return ErrSecurityVerification
	case -3, -9, 31066, 31297:
		return ErrFileNotFound
	case -8, -30, 31061:
		return ErrAlreadyExists
	case 31062:
		return ErrInvalidFileName
	case 31064:
		return ErrAccessDenied
	case 31044, 31326, 31626:
		return ErrUnauthorized
	case -33:
		return ErrTooManyItems
	case 2:
		return ErrTryLater
	}
	return APIError{code, message}
}
