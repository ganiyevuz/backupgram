package main

import (
	"context"
	"io"
	"net/url"
	"os"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// ObjectInfo is one listed object.
type ObjectInfo struct {
	Key  string
	Size int64
}

// Storage is the bucket, as the sync and the subcommands use it.
type Storage interface {
	List(ctx context.Context, prefix string) ([]ObjectInfo, error)
	Put(ctx context.Context, key, path string, size int64) error
	Stat(ctx context.Context, key string) (int64, error)
	Get(ctx context.Context, key string, w io.Writer) error
	Remove(ctx context.Context, key string) error
}

type minioStorage struct {
	c      *minio.Client
	bucket string
}

// NewMinioStorage returns the bucket of env through minio-go (no request is made yet).
func NewMinioStorage(env Env) (Storage, error) {
	u, err := url.Parse(env.Endpoint)
	if err != nil {
		return nil, err
	}
	lookup := minio.BucketLookupAuto
	if env.PathStyle {
		lookup = minio.BucketLookupPath
	}
	c, err := minio.New(u.Host, &minio.Options{
		Creds:        credentials.NewStaticV4(env.AccessKey, env.SecretKey, ""),
		Secure:       u.Scheme == "https",
		Region:       env.Region,
		BucketLookup: lookup,
	})
	if err != nil {
		return nil, err
	}
	return &minioStorage{c: c, bucket: env.Bucket}, nil
}

func (m *minioStorage) List(ctx context.Context, prefix string) ([]ObjectInfo, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel() // stops the listing goroutine when we return early
	var out []ObjectInfo
	for o := range m.c.ListObjects(ctx, m.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if o.Err != nil {
			return nil, o.Err
		}
		out = append(out, ObjectInfo{Key: o.Key, Size: o.Size})
	}
	return out, nil
}

func (m *minioStorage) Put(ctx context.Context, key, path string, size int64) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = m.c.PutObject(ctx, m.bucket, key, f, size, minio.PutObjectOptions{ContentType: "application/octet-stream"})
	return err
}

func (m *minioStorage) Stat(ctx context.Context, key string) (int64, error) {
	info, err := m.c.StatObject(ctx, m.bucket, key, minio.StatObjectOptions{})
	if err != nil {
		return 0, err
	}
	return info.Size, nil
}

func (m *minioStorage) Get(ctx context.Context, key string, w io.Writer) error {
	obj, err := m.c.GetObject(ctx, m.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return err
	}
	defer obj.Close()
	_, err = io.Copy(w, obj)
	return err
}

func (m *minioStorage) Remove(ctx context.Context, key string) error {
	return m.c.RemoveObject(ctx, m.bucket, key, minio.RemoveObjectOptions{})
}
