package playlistimport

import (
	"context"
	"database/sql/driver"
	"strconv"
	"time"
)

// Ordinary import resolution/application and manual snapshot acceptance share
// source admission. Network work never holds a playlist-row transaction open.
func (r *ImportRepository) guardSourceImport(ctx context.Context, id int64) (func(), error) {
	conn, err := r.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	key := "playlist-source-import:" + strconv.FormatInt(id, 10)
	if _, err = conn.ExecContext(ctx, `SELECT pg_advisory_lock(hashtextextended($1,0))`, key); err != nil {
		conn.Close()
		return nil, err
	}
	return func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if _, err := conn.ExecContext(cleanup, `SELECT pg_advisory_unlock(hashtextextended($1,0))`, key); err != nil {
			conn.Raw(func(any) error { return driver.ErrBadConn })
		}
		conn.Close()
	}, nil
}
