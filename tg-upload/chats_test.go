package main

import (
	"reflect"
	"testing"

	"github.com/gotd/td/tg"
)

func TestSplitChatsMultiple(t *testing.T) {
	got, err := splitChats(" 123 , -1001000000222 ,-456")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []chatTarget{
		{raw: "123", peer: &tg.InputPeerUser{UserID: 123}},
		{raw: "-1001000000222", peer: &tg.InputPeerChannel{ChannelID: 1000000222}},
		{raw: "-456", peer: &tg.InputPeerChat{ChatID: 456}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("splitChats = %#v, want %#v", got, want)
	}
}

func TestSplitChatsSingle(t *testing.T) {
	got, err := splitChats("123")
	if err != nil || len(got) != 1 || got[0].raw != "123" {
		t.Fatalf("expected one target for \"123\", got %#v (err %v)", got, err)
	}
}

func TestSplitChatsErrors(t *testing.T) {
	for _, in := range []string{"", "   ", "123,,456", ",123", "123,abc"} {
		if _, err := splitChats(in); err == nil {
			t.Errorf("splitChats(%q): expected error, got nil", in)
		}
	}
}
