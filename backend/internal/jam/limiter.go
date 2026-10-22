package jam

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

type LimitInput struct{ Action, RemoteIP, JamID, MemberSecret string }
type Limiter interface {
	Allow(context.Context, LimitInput) error
}

// A single expiring hash per minute with a fixed field cap prevents random
// unknown Jam/member identifiers creating unbounded keys. No IP/token is stored.
// Global ceiling is deliberate fail-closed backpressure, not tenant isolation.
type RedisLimiter struct {
	Client       redis.UniversalClient
	Prefix       string
	Now          func() time.Time
	MaxFields    int
	GlobalBudget int
}

func NewRedisLimiter(c redis.UniversalClient) *RedisLimiter {
	return &RedisLimiter{Client: c, Prefix: "jam:limit:v1", Now: time.Now, MaxFields: 10000, GlobalBudget: 10000}
}

var limitScript = redis.NewScript(`
local total=redis.call('HINCRBY',KEYS[1],'total',1)
redis.call('EXPIRE',KEYS[1],120)
if total>tonumber(ARGV[1]) then return 0 end
local missing=0
for i=3,#ARGV,2 do if redis.call('HEXISTS',KEYS[1],ARGV[i])==0 then missing=missing+1 end end
if redis.call('HLEN',KEYS[1])+missing>tonumber(ARGV[2]) then return 0 end
local ok=1
for i=3,#ARGV,2 do
 local n=redis.call('HINCRBY',KEYS[1],ARGV[i],1)
 if n>tonumber(ARGV[i+1]) then ok=0 end
end
return ok
`)

func (l *RedisLimiter) Allow(ctx context.Context, in LimitInput) error {
	if l == nil || l.Client == nil || l.MaxFields < 4 || l.GlobalBudget < 1 {
		return ErrUnavailable
	}
	now := l.Now().Unix()
	key := fmt.Sprintf("%s:%d", l.Prefix, now/60*60)
	args := []any{l.GlobalBudget, l.MaxFields}
	add := func(scope, id string, budget int) { args = append(args, hash(scope+":"+id), budget) }
	switch in.Action {
	case "join":
		add("join-ip", in.RemoteIP, 5)
		add("join-jam", in.JamID, 30)
	case "request":
		add("request-member", in.JamID+":"+in.MemberSecret, 5)
		add("request-jam", in.JamID, 30)
	case "read":
		add("read-member", in.JamID+":"+in.MemberSecret, 30)
	case "member":
		add("heartbeat-member", in.JamID+":"+in.MemberSecret, 12)
	case "hostRead":
		add("host-read", in.JamID+":"+in.RemoteIP, 30)
	case "hostWrite":
		add("host-write", in.JamID+":"+in.RemoteIP, 30)
	case "host":
		add("host-second", fmt.Sprint(now)+":"+in.JamID+":"+in.RemoteIP, 1)
	default:
		return ErrUnavailable
	}
	n, e := limitScript.Run(ctx, l.Client, []string{key}, args...).Int()
	if e != nil {
		return ErrUnavailable
	}
	if n != 1 {
		return ErrLimited
	}
	return nil
}
