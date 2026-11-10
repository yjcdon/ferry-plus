package baidu

import (
	"context"
	"crypto/md5"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
)

type Account struct {
	Username string  `json:"username"`
	UK       int64   `json:"uk"`
	UID      *uint64 `json:"uid,omitempty"`
	BDSToken string  `json:"bdstoken"`
}

type Capacity struct{ Total, Used int64 }

// Validate checks the netdisk credential and returns the account identity. Tieba
// provides an optional UID and display name, but is not required to sign in.
func (c *Client) Validate(ctx context.Context) (Account, error) {
	token, err := c.bdstoken(ctx)
	if err != nil {
		return Account{}, err
	}
	uk, name, err := c.userInfo(ctx)
	if err != nil {
		return Account{}, err
	}
	uid, tiebaName := c.lookupUID(ctx)
	if err := ctx.Err(); err != nil {
		return Account{}, err
	}
	if err := c.lifetime.Err(); err != nil {
		return Account{}, err
	}
	if tiebaName != "" {
		name = tiebaName
	}
	if uid != nil {
		value := *uid
		uid = &value
	}
	return Account{name, uk, uid, token}, nil
}

func (c *Client) bdstoken(ctx context.Context) (string, error) {
	address := endpoint(pan+"/api/gettemplatevariable", url.Values{"clienttype": {"0"}, "app_id": {panID}, "fields": {`["bdstoken"]`}})
	j, err := c.checked(ctx, request{url: address, cookies: c.credential.Cookies}, "errno", "")
	if err != nil {
		return "", err
	}
	token := str(obj(j["result"])["bdstoken"])
	if token == "" {
		return "", ErrLoginExpired
	}
	return token, nil
}

func (c *Client) userInfo(ctx context.Context) (int64, string, error) {
	address := endpoint(pan+"/api/user/getinfo", url.Values{"need_selfinfo": {"1"}})
	j, err := c.checked(ctx, request{url: address, cookies: c.credential.Cookies}, "errno", "")
	if err != nil {
		return 0, "", err
	}
	records := list(j["records"])
	if len(records) != 1 {
		return 0, "", ErrLoginExpired
	}
	record := obj(records[0])
	uk, ok := integer(record["uk"])
	if !ok || uk <= 0 {
		return 0, "", ErrLoginExpired
	}
	for _, field := range []string{"baidu_name", "netdisk_name", "uname"} {
		if name := str(record[field]); name != "" {
			return uk, name, nil
		}
	}
	return uk, "", nil
}

func (c *Client) lookupUID(ctx context.Context) (*uint64, string) {
	c.uidMu.Lock()
	defer c.uidMu.Unlock()
	if c.uidChecked {
		return c.uid, c.uidName
	}
	uid, name, err := c.tiebaLogin(ctx)
	if ctx.Err() == nil && c.lifetime.Err() == nil {
		c.uidChecked = true
		if err == nil {
			c.uid, c.uidName = &uid, name
		}
	}
	return c.uid, c.uidName
}

func (c *Client) tiebaLogin(ctx context.Context) (uint64, string, error) {
	now := strconv.FormatInt(c.now().Unix(), 10)
	const imei = "860983036542682"
	cuid := strings.ToUpper(md5Text("_7.0.0.0_"+imei+"_mini_ad_wandoujia")) + "|286245630389068"
	values := url.Values{
		"bdusstoken": {c.credential.BDUSS + "|null"}, "channel_id": {""}, "channel_uid": {""},
		"stErrorNums": {"0"}, "subapp_type": {"mini"}, "timestamp": {now + "922"},
		"_client_type": {"2"}, "_client_version": {"7.0.0.0"}, "_phone_imei": {imei},
		"from": {"mini_ad_wandoujia"}, "model": {"HUAWEI MLA-AL10"}, "cuid": {cuid},
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	var joined strings.Builder
	for _, key := range keys {
		joined.WriteString(key + "=" + values.Get(key))
	}
	values.Set("sign", strings.ToUpper(md5Text(joined.String()+"tiebaclient!!!")))
	r := request{url: tieba + "/c/s/login", ua: "bdtb for Android 6.9.2.1", cookies: []Cookie{{"ka", "open"}}, headers: http.Header{"Net": {"1"}, "Client_logid": {now + "416"}}}.form(values)
	j, _, err := c.json(ctx, r)
	if err != nil {
		return 0, "", err
	}
	if str(j["error_code"]) != "0" {
		code, ok := integer(j["error_code"])
		if !ok {
			code = -1
		}
		return 0, "", APIError{code, str(j["error_msg"])}
	}
	user := obj(j["user"])
	uid, err := strconv.ParseUint(str(user["id"]), 10, 64)
	if err != nil {
		return 0, "", ErrInvalidResponse
	}
	return uid, str(user["name"]), nil
}

func md5Text(s string) string { return fmt.Sprintf("%x", md5.Sum([]byte(s))) }

// Capacity reads the account's used and total bytes.
func (c *Client) Capacity(ctx context.Context) (Capacity, error) {
	j, err := c.checked(ctx, request{url: pan + "/api/quota", ua: netdiskUA, cookies: c.credential.Cookies,
		headers: http.Header{"Referer": {pan + "/disk/main"}}}, "errno", "")
	if err != nil {
		return Capacity{}, err
	}
	code, codeOK := j["errno"].(json.Number)
	total, totalOK := j["total"].(json.Number)
	used, usedOK := j["used"].(json.Number)
	if !codeOK || !totalOK || !usedOK || num(code) != 0 {
		return Capacity{}, ErrInvalidResponse
	}
	t, tOK := integer(total)
	u, uOK := integer(used)
	if !tOK || !uOK || t < 0 || u < 0 {
		return Capacity{}, ErrInvalidResponse
	}
	return Capacity{t, u}, nil
}
