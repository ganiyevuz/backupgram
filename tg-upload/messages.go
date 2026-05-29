package main

import (
	"fmt"

	"github.com/gotd/td/tg"
)

// messageIDFromUpdates extracts the id of a just-sent message from the Updates
// returned by a send. It checks the common carriers: UpdateMessageID (maps the
// client random_id to the new id), and the new-message updates.
func messageIDFromUpdates(u tg.UpdatesClass) (int, bool) {
	var list []tg.UpdateClass
	switch v := u.(type) {
	case *tg.Updates:
		list = v.Updates
	case *tg.UpdatesCombined:
		list = v.Updates
	default:
		return 0, false
	}
	for _, upd := range list {
		switch m := upd.(type) {
		case *tg.UpdateMessageID:
			return m.ID, true
		case *tg.UpdateNewChannelMessage:
			if msg, ok := m.Message.(*tg.Message); ok {
				return msg.ID, true
			}
		case *tg.UpdateNewMessage:
			if msg, ok := m.Message.(*tg.Message); ok {
				return msg.ID, true
			}
		}
	}
	return 0, false
}

// documentFromMessages finds the message with the given id in a getMessages
// response and returns its document plus the document's filename. It errors if
// the message is absent or carries no document.
func documentFromMessages(msgs tg.MessagesMessagesClass, id int) (*tg.Document, string, error) {
	var list []tg.MessageClass
	switch v := msgs.(type) {
	case *tg.MessagesMessages:
		list = v.Messages
	case *tg.MessagesMessagesSlice:
		list = v.Messages
	case *tg.MessagesChannelMessages:
		list = v.Messages
	default:
		return nil, "", fmt.Errorf("unexpected messages response %T", msgs)
	}
	for _, mc := range list {
		msg, ok := mc.(*tg.Message)
		if !ok || msg.ID != id {
			continue
		}
		media, ok := msg.Media.(*tg.MessageMediaDocument)
		if !ok {
			return nil, "", fmt.Errorf("message %d has no document", id)
		}
		doc, ok := media.Document.(*tg.Document)
		if !ok {
			return nil, "", fmt.Errorf("message %d document is unavailable", id)
		}
		name := fmt.Sprintf("restore-%d", id)
		for _, attr := range doc.Attributes {
			if fn, ok := attr.(*tg.DocumentAttributeFilename); ok && fn.FileName != "" {
				name = fn.FileName
				break
			}
		}
		return doc, name, nil
	}
	return nil, "", fmt.Errorf("message %d not found", id)
}
