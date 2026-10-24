// native-fixture composes existing production Go auth/library/playback handlers
// with a disposable PostgreSQL database and a local synthetic WAV object. It is
// opt-in development tooling, never a replacement server or schema authority.
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

type object struct {
	bytes         []byte
	token, origin string
}

func (o *object) StatObject(_ context.Context, key string) (*storage.ObjectInfo, error) {
	if key != "native-fixture.wav" {
		return nil, fmt.Errorf("unknown fixture object")
	}
	return &storage.ObjectInfo{Size: int64(len(o.bytes)), ContentType: "audio/wav", ETag: fmt.Sprintf("%x", sha256.Sum256(o.bytes))}, nil
}
func (o *object) PresignGetObject(_ context.Context, key string, _ time.Duration) (string, error) {
	if key != "native-fixture.wav" {
		return "", fmt.Errorf("unknown fixture object")
	}
	return o.origin + "/fixture-audio/" + o.token + ".wav", nil
}
func secret() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func wav() []byte {
	const rate = 48000
	const seconds = 30
	pcm := make([]byte, rate*seconds*2)
	for n := 0; n < rate*seconds; n++ { // Quiet synthetic 440 Hz, bounded fade at both ends.
		envelope := math.Min(1, math.Min(float64(n)/2400, float64(rate*seconds-n)/2400))
		value := int16(0.08 * 32767 * math.Sin(2*math.Pi*440*float64(n)/rate) * envelope)
		binary.LittleEndian.PutUint16(pcm[n*2:], uint16(value))
	}
	b := make([]byte, 44+len(pcm))
	copy(b, "RIFF")
	binary.LittleEndian.PutUint32(b[4:], uint32(len(b)-8))
	copy(b[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(b[16:], 16)
	binary.LittleEndian.PutUint16(b[20:], 1)
	binary.LittleEndian.PutUint16(b[22:], 1)
	binary.LittleEndian.PutUint32(b[24:], rate)
	binary.LittleEndian.PutUint32(b[28:], rate*2)
	binary.LittleEndian.PutUint16(b[32:], 2)
	binary.LittleEndian.PutUint16(b[34:], 16)
	copy(b[36:], "data")
	binary.LittleEndian.PutUint32(b[40:], uint32(len(pcm)))
	copy(b[44:], pcm)
	return b
}
func main() {
	dsn := os.Getenv("SOUNDQ_NATIVE_FIXTURE_DSN")
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		log.Fatal("protected fixture DSN refused")
	}
	parsed, err := url.Parse(dsn)
	if err != nil || parsed.Hostname() != "127.0.0.1" || !strings.HasPrefix(strings.TrimPrefix(parsed.Path, "/"), "soundq_native_fixture_") {
		log.Fatal("refusing non-owned fixture DSN")
	}
	port := os.Getenv("SOUNDQ_NATIVE_FIXTURE_PORT")
	if port == "" {
		port = "54761"
	}
	if _, err := strconv.Atoi(port); err != nil {
		log.Fatal("invalid fixture port")
	}
	home := os.Getenv("SOUNDQ_NATIVE_FIXTURE_HOME")
	if home == "" {
		log.Fatal("fixture home required")
	}
	if err := os.MkdirAll(home, 0700); err != nil {
		log.Fatal(err)
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatal("open fixture database failed")
	}
	defer raw.Close()
	database := &db.DB{DB: raw}
	if err := database.CheckDatabaseNotProtected(context.Background()); err != nil {
		log.Fatal("protected fixture database refused")
	}
	var name string
	if err := raw.QueryRow("SELECT current_database()").Scan(&name); err != nil || !strings.HasPrefix(name, "soundq_native_fixture_") {
		log.Fatal("database ownership refused")
	}
	// Refuse a populated DB. Never TRUNCATE, delete accounts, or reuse live data.
	var hasUsers bool
	if err := raw.QueryRow("SELECT to_regclass('public.users') IS NOT NULL").Scan(&hasUsers); err != nil || hasUsers {
		log.Fatal("fixture requires a new empty database")
	}
	if err := database.Migrate(); err != nil {
		log.Fatal(err)
	}
	users := db.NewUserRepository(database)
	tokens := db.NewTokenRepository(database)
	service := auth.NewService(users, tokens, secret())
	handlers := auth.NewHandlers(service)
	email := "native-" + secret()[:12] + "@example.invalid"
	password := secret()
	account, err := service.Register(context.Background(), email, password, "native-fixture")
	if err != nil {
		log.Fatal("fixture registration failed")
	}
	bytes := wav()
	tx, err := raw.Begin()
	if err != nil {
		log.Fatal(err)
	}
	for i := 1; i <= 500; i++ {
		var id int64
		err = tx.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,album,duration_ms,storage_key,file_size_bytes,codec,sample_rate_hz,channels,content_type,version) VALUES($1,$2,'Synthetic Fixture','Native Port',30000,'native-fixture.wav',$3,'pcm_s16le',48000,1,'audio/wav','native-fixture-v1') RETURNING id`, fmt.Sprintf("%064x", i), fmt.Sprintf("Native Fixture %03d", i), len(bytes)).Scan(&id)
		if err != nil {
			log.Fatal(err)
		}
		if _, err = tx.Exec(`INSERT INTO user_library(user_id,track_id,added_at) VALUES($1,$2,$3)`, account.User.ID, id, time.Now().Add(time.Duration(i)*time.Second)); err != nil {
			log.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "fixture.wav"), bytes, 0600); err != nil {
		log.Fatal(err)
	}
	asset := &object{bytes: bytes, token: secret(), origin: "http://127.0.0.1:" + port}
	library := api.NewLibraryHandlers(db.NewTrackRepository(database), db.NewLibraryRepository(database))
	playback := api.NewPlaybackHandlers(db.NewTrackRepository(database), db.NewLibraryRepository(database), asset)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/auth/login", handlers.Login)
	mux.HandleFunc("POST /api/v1/auth/register", handlers.Register)
	mux.HandleFunc("POST /api/v1/auth/refresh", handlers.Refresh)
	protected := auth.Middleware(service)
	mux.Handle("POST /api/v1/auth/logout", protected(http.HandlerFunc(handlers.Logout)))
	mux.Handle("GET /api/v1/library", protected(http.HandlerFunc(library.GetLibrary)))
	mux.Handle("POST /api/v1/playback/urls", protected(http.HandlerFunc(playback.CreatePlaybackURLs)))
	mux.HandleFunc("GET /fixture-audio/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/fixture-audio/"+asset.token+".wav" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "audio/wav")
		http.ServeFile(w, r, filepath.Join(home, "fixture.wav"))
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"status":"ok","fixture":"native-port"}`))
	})
	// Private credentials only, never log them or place them in source/evidence.
	private := map[string]any{"email": email, "password": password, "access_token": account.AccessToken, "refresh_token": account.RefreshToken, "account_id": account.User.ID}
	payload, _ := json.Marshal(private)
	if err := os.WriteFile(filepath.Join(home, "credentials.json"), payload, 0600); err != nil {
		log.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("native fixture ready on loopback port %s, 500 synthetic tracks", port)
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(server.Serve(listener))
}
