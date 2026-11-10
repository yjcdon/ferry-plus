package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

type Provider string

const (
	Baidu Provider = "baidu"
	Quark Provider = "quark"
)

// AccountState separates a login that needs renewal from a retryable problem.
type AccountState int

const (
	LoggedOut AccountState = iota
	Checking
	LoggedIn
	Expired
	AccountProblem
)

// AccountSession is the verified identity and client available to the workspace.
type AccountSession struct {
	State   AccountState
	ID      string
	Name    string
	Problem string
	Baidu   *baidu.Client
	Quark   *quark.Client
}

type savedAccount struct {
	ID    string            `json:"id"`
	Name  string            `json:"name"`
	Baidu *baidu.Credential `json:"baidu,omitempty"`
	Quark *quark.Credential `json:"quark,omitempty"`
}

// CheckedLogin is a provider result ready for an explicit commit.
type CheckedLogin struct {
	provider Provider
	saved    savedAccount
	session  AccountSession
}

func (l *CheckedLogin) revoke() {
	if l.session.Baidu != nil {
		l.session.Baidu.Revoke()
	}
	if l.session.Quark != nil {
		l.session.Quark.Revoke()
	}
}

// Discard cancels a verified attempt that the user closed before saving.
func (l *CheckedLogin) Discard() { l.revoke() }

var errBaiduAccountChanged = errors.New("返回的百度账号与已保存账号不同，请重新登录。")

type credentialRecords interface {
	ReadCredential(string) ([]byte, error)
	WriteCredential(string, []byte) error
	RemoveCredential(string) error
}

type accountSlot struct {
	mu      sync.Mutex
	current atomic.Pointer[AccountSession]
}

// Accounts validates two independent provider sessions and persists their
// credentials before making new clients visible to the workspace.
type Accounts struct {
	data         credentialRecords
	http         *http.Client
	onExpired    func(Provider)
	baidu, quark accountSlot
}

func NewAccounts(data credentialRecords, client *http.Client) *Accounts {
	return &Accounts{data: data, http: client}
}

// OnExpired registers the workspace callback before account requests start.
func (a *Accounts) OnExpired(notify func(Provider)) {
	a.onExpired = notify
}

// ExpireSession retires only the session that received an explicit
// authentication failure. The saved identity remains available for login.
func (a *Accounts) ExpireSession(provider Provider, session AccountSession, err error) bool {
	if !isLoginExpired(provider, err) {
		return false
	}
	slot := a.slot(provider)
	slot.mu.Lock()
	current := slot.current.Load()
	if current == nil || current.State != LoggedIn || !sameDirectorySession(session, *current) {
		slot.mu.Unlock()
		return false
	}
	slot.replace(&AccountSession{State: Expired, ID: current.ID, Name: current.Name, Problem: "登录已失效，请重新登录。"})
	slot.mu.Unlock()
	if a.onExpired != nil {
		a.onExpired(provider)
	}
	return true
}

func isLoginExpired(provider Provider, err error) bool {
	switch provider {
	case Baidu:
		return errors.Is(err, baidu.ErrLoginExpired) || errors.Is(err, errBaiduAccountChanged)
	case Quark:
		return errors.Is(err, quark.ErrLoginExpired) || errors.Is(err, quark.ErrAccountChanged)
	default:
		return false
	}
}

func (a *Accounts) slot(provider Provider) *accountSlot {
	if provider == Baidu {
		return &a.baidu
	}
	return &a.quark
}

func (a *Accounts) Session(provider Provider) AccountSession {
	if session := a.slot(provider).current.Load(); session != nil {
		return *session
	}
	return AccountSession{State: LoggedOut}
}

func (a *Accounts) CheckBaidu(ctx context.Context, credential baidu.Credential) (*CheckedLogin, error) {
	return a.check(ctx, Baidu, savedAccount{Baidu: &credential})
}

func (a *Accounts) CheckQuark(ctx context.Context, credential quark.Credential) (*CheckedLogin, error) {
	return a.check(ctx, Quark, savedAccount{Quark: &credential})
}

func (a *Accounts) check(ctx context.Context, provider Provider, saved savedAccount) (*CheckedLogin, error) {
	if provider == Baidu {
		client := baidu.New(*saved.Baidu, a.http)
		login, err := checkBaidu(ctx, saved, client)
		if err != nil {
			client.Revoke()
		}
		return login, err
	}
	client := quark.New(*saved.Quark, a.http)
	result, err := client.Validate(ctx, saved.ID)
	if err != nil {
		client.Revoke()
		return nil, err
	}
	saved.ID, saved.Name, saved.Quark = result.Account.ID, result.Account.Nickname, &result.Credential
	return &CheckedLogin{
		provider: Quark,
		saved:    saved,
		session:  AccountSession{State: LoggedIn, ID: saved.ID, Name: saved.Name, Quark: client},
	}, nil
}

func checkBaidu(ctx context.Context, saved savedAccount, client *baidu.Client) (*CheckedLogin, error) {
	account, err := client.Validate(ctx)
	if err != nil {
		return nil, err
	}
	id := strconv.FormatInt(account.UK, 10)
	if saved.ID != "" && id != saved.ID {
		return nil, errBaiduAccountChanged
	}
	saved.ID, saved.Name = id, account.Username
	return &CheckedLogin{
		provider: Baidu,
		saved:    saved,
		session:  AccountSession{State: LoggedIn, ID: saved.ID, Name: saved.Name, Baidu: client},
	}, nil
}

// Install saves the verified login and retires the prior client after success.
func (a *Accounts) Install(login *CheckedLogin) error {
	slot := a.slot(login.provider)
	slot.mu.Lock()
	defer slot.mu.Unlock()
	return a.install(slot, login)
}

func (a *Accounts) install(slot *accountSlot, login *CheckedLogin) error {
	if err := a.save(login.provider, login.saved); err != nil {
		login.revoke()
		return err
	}
	if client := login.session.Quark; client != nil {
		client.ObserveCredentialChanges(func(credential quark.Credential) error {
			slot.mu.Lock()
			defer slot.mu.Unlock()
			if current := slot.current.Load(); current == nil || current.Quark != client {
				return context.Canceled
			}
			saved := login.saved
			saved.Quark = &credential
			return a.save(Quark, saved)
		})
	}
	slot.replace(&login.session)
	return nil
}

// Restore validates only the saved identity and publishes only if the user
// has not changed the account while the request ran.
func (a *Accounts) Restore(ctx context.Context, provider Provider, notify func()) {
	slot := a.slot(provider)
	start := slot.current.Load()
	var saved savedAccount
	data, err := a.data.ReadCredential(string(provider))
	if errors.Is(err, fs.ErrNotExist) {
		return
	}
	if err == nil {
		err = json.Unmarshal(data, &saved)
		if err == nil && (saved.ID == "" || provider == Baidu && saved.Baidu == nil || provider == Quark && saved.Quark == nil) {
			err = errors.New("账号记录缺少身份或凭据")
		}
	}
	if err != nil {
		if slot.current.CompareAndSwap(start, &AccountSession{State: AccountProblem, Problem: "登录信息读取失败：" + err.Error()}) {
			notify()
		}
		return
	}

	current := &AccountSession{State: Checking, ID: saved.ID, Name: saved.Name}
	if provider == Baidu {
		// The original app restores the previously verified Baidu session
		// immediately. Only an explicit authentication failure expires it.
		current.State = LoggedIn
		current.Baidu = baidu.New(*saved.Baidu, a.http)
	}
	if !slot.current.CompareAndSwap(start, current) {
		if current.Baidu != nil {
			current.Baidu.Revoke()
		}
		return
	}
	notify()

	var login *CheckedLogin
	if provider == Baidu {
		login, err = checkBaidu(ctx, saved, current.Baidu)
	} else {
		login, err = a.check(ctx, provider, saved)
	}

	slot.mu.Lock()
	if ctx.Err() != nil || slot.current.Load() != current {
		slot.mu.Unlock()
		if login != nil && login.session.Quark != nil {
			login.revoke()
		}
		return
	}
	expired := isLoginExpired(provider, err)
	if err == nil {
		err = a.install(slot, login)
	}
	if expired || err != nil && (provider == Quark || login != nil) {
		state := AccountProblem
		if expired {
			state = Expired
		}
		slot.replace(&AccountSession{State: state, ID: saved.ID, Name: saved.Name, Problem: err.Error()})
	}
	slot.mu.Unlock()
	notify()
}

// Logout removes the saved session before clearing its usable client.
func (a *Accounts) Logout(provider Provider) error {
	slot := a.slot(provider)
	slot.mu.Lock()
	defer slot.mu.Unlock()
	if err := a.data.RemoveCredential(string(provider)); err != nil {
		return err
	}
	slot.replace(&AccountSession{State: LoggedOut})
	return nil
}

func (a *Accounts) save(provider Provider, saved savedAccount) error {
	data, err := json.Marshal(saved)
	if err != nil {
		return fmt.Errorf("编码账号：%w", err)
	}
	return a.data.WriteCredential(string(provider), data)
}

func (s *accountSlot) replace(session *AccountSession) {
	old := s.current.Swap(session)
	if old == nil {
		return
	}
	if old.Baidu != nil && old.Baidu != session.Baidu {
		old.Baidu.Revoke()
	}
	if old.Quark != nil && old.Quark != session.Quark {
		old.Quark.Revoke()
	}
}
