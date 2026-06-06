package httpx

import (
	"encoding/json"
	"net/http"
)

// Error carries an HTTP status so any layer can return a status-aware error.
type Error struct {
	Status int
	Msg    string
}

func (e *Error) Error() string { return e.Msg }

func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func WriteError(w http.ResponseWriter, err error) {
	status := 500
	if ae, ok := err.(*Error); ok {
		status = ae.Status
	}
	WriteJSON(w, status, map[string]string{"error": err.Error()})
}

// DecodeJSON decodes the request body into dst, returning a 400 *Error on failure.
func DecodeJSON(r *http.Request, dst any) error {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		return &Error{Status: 400, Msg: "invalid JSON body"}
	}
	return nil
}
