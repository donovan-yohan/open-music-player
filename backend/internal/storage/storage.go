package storage

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/openmusicplayer/backend/internal/config"
)

// TrackMetadata contains the metadata used for identity hash generation
type TrackMetadata struct {
	Title      string `json:"title"`
	Artist     string `json:"artist,omitempty"`
	Album      string `json:"album,omitempty"`
	DurationMs int    `json:"duration_ms,omitempty"`
}

// UploadResult contains the result of an upload operation
type UploadResult struct {
	StorageKey   string `json:"storage_key"`
	IdentityHash string `json:"identity_hash"`
	IsNew        bool   `json:"is_new"` // false if file already existed (deduplicated)
}

// Storage defines the interface for audio file storage
type Storage interface {
	// Upload uploads an audio file to storage with deduplication
	Upload(ctx context.Context, filePath string, metadata TrackMetadata) (*UploadResult, error)
	// Exists checks if a file exists in storage by identity hash
	Exists(ctx context.Context, identityHash string) (bool, error)
	// GetURL returns the URL for accessing a stored file
	GetURL(ctx context.Context, identityHash string) (string, error)
	// Delete removes a file from storage
	Delete(ctx context.Context, identityHash string) error
}

// S3Storage implements Storage using S3-compatible storage (AWS S3 or MinIO)
type S3Storage struct {
	client *s3.Client
	bucket string
}

// NewS3Storage creates a new S3Storage instance
func NewS3Storage(cfg *config.Config) (*S3Storage, error) {
	// Create S3 client with static credentials and custom endpoint for MinIO
	opts := s3.Options{
		Region:       cfg.S3Region,
		Credentials:  credentials.NewStaticCredentialsProvider(cfg.S3AccessKey, cfg.S3SecretKey, ""),
		UsePathStyle: cfg.S3UsePathStyle, // Required for MinIO
	}

	// Set custom endpoint for MinIO/non-AWS S3
	if cfg.S3Endpoint != "" {
		opts.BaseEndpoint = aws.String(cfg.S3Endpoint)
	}

	client := s3.New(opts)

	return &S3Storage{
		client: client,
		bucket: cfg.S3Bucket,
	}, nil
}

// GenerateIdentityHash creates a unique hash for track deduplication
// Based on normalized title, artist, and duration
func GenerateIdentityHash(metadata TrackMetadata) string {
	// Normalize strings: lowercase, trim whitespace
	normalizedTitle := strings.ToLower(strings.TrimSpace(metadata.Title))
	normalizedArtist := strings.ToLower(strings.TrimSpace(metadata.Artist))

	// Create deterministic string for hashing
	// Format: title|artist|duration_ms
	hashInput := fmt.Sprintf("%s|%s|%d", normalizedTitle, normalizedArtist, metadata.DurationMs)

	hash := sha256.Sum256([]byte(hashInput))
	return hex.EncodeToString(hash[:])
}

// storageKey returns the S3 key for a given identity hash
func (s *S3Storage) storageKey(identityHash string) string {
	return fmt.Sprintf("audio/%s/audio.mp3", identityHash)
}

// metadataKey returns the S3 key for metadata JSON
func (s *S3Storage) metadataKey(identityHash string) string {
	return fmt.Sprintf("audio/%s/metadata.json", identityHash)
}

// Upload uploads an audio file to S3 with deduplication
func (s *S3Storage) Upload(ctx context.Context, filePath string, metadata TrackMetadata) (*UploadResult, error) {
	// Generate identity hash for deduplication
	identityHash := GenerateIdentityHash(metadata)

	// Check if file already exists
	exists, err := s.Exists(ctx, identityHash)
	if err != nil {
		return nil, fmt.Errorf("failed to check existence: %w", err)
	}

	if exists {
		// File already exists, skip upload (deduplication)
		return &UploadResult{
			StorageKey:   s.storageKey(identityHash),
			IdentityHash: identityHash,
			IsNew:        false,
		}, nil
	}

	// Open the file for upload
	file, err := os.Open(filePath)
	if err != nil {
		return nil, fmt.Errorf("failed to open file: %w", err)
	}
	defer file.Close()

	// Get file info for content length
	fileInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("failed to stat file: %w", err)
	}

	// Upload audio file
	audioKey := s.storageKey(identityHash)
	_, err = s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(s.bucket),
		Key:           aws.String(audioKey),
		Body:          file,
		ContentLength: aws.Int64(fileInfo.Size()),
		ContentType:   aws.String("audio/mpeg"),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to upload audio: %w", err)
	}

	// Upload metadata JSON
	metadataJSON, err := json.Marshal(metadata)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal metadata: %w", err)
	}

	metaKey := s.metadataKey(identityHash)
	_, err = s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(metaKey),
		Body:        strings.NewReader(string(metadataJSON)),
		ContentType: aws.String("application/json"),
	})
	if err != nil {
		// Try to clean up the audio file if metadata upload fails
		_ = s.Delete(ctx, identityHash)
		return nil, fmt.Errorf("failed to upload metadata: %w", err)
	}

	// Clean up temp file after successful upload
	if err := os.Remove(filePath); err != nil {
		// Log but don't fail - the upload succeeded
		fmt.Printf("warning: failed to remove temp file %s: %v\n", filePath, err)
	}

	return &UploadResult{
		StorageKey:   audioKey,
		IdentityHash: identityHash,
		IsNew:        true,
	}, nil
}

// Exists checks if a file exists in S3 by identity hash
func (s *S3Storage) Exists(ctx context.Context, identityHash string) (bool, error) {
	key := s.storageKey(identityHash)
	_, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		// Check if error is "not found"
		var notFound *types.NotFound
		if ok := isNotFoundError(err); ok {
			return false, nil
		}
		// Also check for NoSuchKey
		var noSuchKey *types.NoSuchKey
		if isNoSuchKeyError(err) {
			return false, nil
		}
		_, _ = notFound, noSuchKey // suppress unused warnings
		return false, fmt.Errorf("failed to check existence: %w", err)
	}
	return true, nil
}

// isNotFoundError checks if the error indicates the object was not found
func isNotFoundError(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "NotFound") ||
		strings.Contains(err.Error(), "not found") ||
		strings.Contains(err.Error(), "404")
}

// isNoSuchKeyError checks if the error indicates NoSuchKey
func isNoSuchKeyError(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "NoSuchKey")
}

// GetURL returns the URL for accessing a stored file
func (s *S3Storage) GetURL(ctx context.Context, identityHash string) (string, error) {
	key := s.storageKey(identityHash)

	// For MinIO/S3 with public access, construct direct URL
	// In production, you might want to use presigned URLs
	return fmt.Sprintf("%s/%s", s.bucket, key), nil
}

// Delete removes a file and its metadata from S3
func (s *S3Storage) Delete(ctx context.Context, identityHash string) error {
	// Delete audio file
	audioKey := s.storageKey(identityHash)
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(audioKey),
	})
	if err != nil {
		return fmt.Errorf("failed to delete audio: %w", err)
	}

	// Delete metadata file
	metaKey := s.metadataKey(identityHash)
	_, err = s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(metaKey),
	})
	if err != nil {
		return fmt.Errorf("failed to delete metadata: %w", err)
	}

	return nil
}

// UploadFromReader uploads an audio file from an io.Reader
func (s *S3Storage) UploadFromReader(ctx context.Context, reader io.Reader, contentLength int64, metadata TrackMetadata) (*UploadResult, error) {
	// Generate identity hash for deduplication
	identityHash := GenerateIdentityHash(metadata)

	// Check if file already exists
	exists, err := s.Exists(ctx, identityHash)
	if err != nil {
		return nil, fmt.Errorf("failed to check existence: %w", err)
	}

	if exists {
		return &UploadResult{
			StorageKey:   s.storageKey(identityHash),
			IdentityHash: identityHash,
			IsNew:        false,
		}, nil
	}

	// Upload audio file
	audioKey := s.storageKey(identityHash)
	_, err = s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(s.bucket),
		Key:           aws.String(audioKey),
		Body:          reader,
		ContentLength: aws.Int64(contentLength),
		ContentType:   aws.String("audio/mpeg"),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to upload audio: %w", err)
	}

	// Upload metadata JSON
	metadataJSON, err := json.Marshal(metadata)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal metadata: %w", err)
	}

	metaKey := s.metadataKey(identityHash)
	_, err = s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(metaKey),
		Body:        strings.NewReader(string(metadataJSON)),
		ContentType: aws.String("application/json"),
	})
	if err != nil {
		_ = s.Delete(ctx, identityHash)
		return nil, fmt.Errorf("failed to upload metadata: %w", err)
	}

	return &UploadResult{
		StorageKey:   audioKey,
		IdentityHash: identityHash,
		IsNew:        true,
	}, nil
}
