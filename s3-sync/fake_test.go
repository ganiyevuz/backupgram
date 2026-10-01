package main

import (
	"context"
	"errors"
	"io"
	"os"
	"sort"
	"strings"
)

// fakeStorage is an in-memory bucket with failure injection.
type fakeStorage struct {
	objects   map[string][]byte
	putErr    map[string]error
	removeErr map[string]error
	listErr   error
	shortStat map[string]bool // Stat reports one byte less: a truncated upload
}

func newFake() *fakeStorage {
	return &fakeStorage{objects: map[string][]byte{}, putErr: map[string]error{}, removeErr: map[string]error{}, shortStat: map[string]bool{}}
}

func (f *fakeStorage) List(_ context.Context, prefix string) ([]ObjectInfo, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	var out []ObjectInfo
	for k, v := range f.objects {
		if strings.HasPrefix(k, prefix) {
			out = append(out, ObjectInfo{Key: k, Size: int64(len(v))})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

func (f *fakeStorage) Put(_ context.Context, key, path string, _ int64) error {
	if err := f.putErr[key]; err != nil {
		return err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	f.objects[key] = b
	return nil
}

func (f *fakeStorage) Stat(_ context.Context, key string) (int64, error) {
	b, ok := f.objects[key]
	if !ok {
		return 0, errors.New("The specified key does not exist.")
	}
	n := int64(len(b))
	if f.shortStat[key] {
		n--
	}
	return n, nil
}

func (f *fakeStorage) Get(_ context.Context, key string, w io.Writer) error {
	b, ok := f.objects[key]
	if !ok {
		return errors.New("The specified key does not exist.")
	}
	_, err := w.Write(b)
	return err
}

func (f *fakeStorage) Remove(_ context.Context, key string) error {
	if err := f.removeErr[key]; err != nil {
		return err
	}
	delete(f.objects, key)
	return nil
}
