package middleware

import (
	"log"
	"net/http"
	"time"
)

// statusWriter wraps ResponseWriter to capture the status code and bytes written.
type statusWriter struct {
	http.ResponseWriter
	status int
	size   int
}

func (sw *statusWriter) WriteHeader(code int) {
	sw.status = code
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *statusWriter) Write(b []byte) (int, error) {
	n, err := sw.ResponseWriter.Write(b)
	sw.size += n
	return n, err
}

// Logging wraps every HTTP request with structured log output:
// [IP] METHOD /path → STATUS (duration) Nbytes
func Logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r)
		log.Printf("[%s] %s %s → %d (%s) %dB",
			r.RemoteAddr,
			r.Method,
			r.URL.RequestURI(),
			sw.status,
			time.Since(start).Round(time.Millisecond),
			sw.size,
		)
	})
}
