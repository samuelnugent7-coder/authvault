package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sync"

	"golang.org/x/crypto/argon2"
)

// Argon2id parameters
const (
	argonTime    = 3
	argonMemory  = 64 * 1024 // 64MB
	argonThreads = 4
	argonKeyLen  = 32
	argonSaltLen = 32
)

var (
	activeKey []byte
	keyMu     sync.RWMutex
)

// GenerateSalt returns a random hex-encoded salt.
func GenerateSalt() (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	return hex.EncodeToString(salt), nil
}

// DeriveKey uses Argon2id to derive a 32-byte AES key from the password and hex-encoded salt.
func DeriveKey(password, saltHex string) ([]byte, error) {
	salt, err := hex.DecodeString(saltHex)
	if err != nil {
		return nil, fmt.Errorf("invalid salt: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return key, nil
}

// HashPassword hashes a password for storage/verification using Argon2id with a fresh salt.
// Format: hex(salt):base64(hash)
func HashPassword(password string) (string, string, error) {
	saltHex, err := GenerateSalt()
	if err != nil {
		return "", "", err
	}
	key, err := DeriveKey(password, saltHex)
	if err != nil {
		return "", "", err
	}
	return saltHex, base64.StdEncoding.EncodeToString(key), nil
}

// VerifyPassword checks a password against the stored salt and hash.
func VerifyPassword(password, saltHex, expectedB64 string) bool {
	key, err := DeriveKey(password, saltHex)
	if err != nil {
		return false
	}
	expected, err := base64.StdEncoding.DecodeString(expectedB64)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(key, expected) == 1
}

// SetActiveKey stores the session encryption key in memory.
func SetActiveKey(key []byte) {
	keyMu.Lock()
	defer keyMu.Unlock()
	activeKey = make([]byte, len(key))
	copy(activeKey, key)
}

// ClearActiveKey wipes the session key from memory.
func ClearActiveKey() {
	keyMu.Lock()
	defer keyMu.Unlock()
	for i := range activeKey {
		activeKey[i] = 0
	}
	activeKey = nil
}

// IsUnlocked returns whether there is an active session key.
func IsUnlocked() bool {
	keyMu.RLock()
	defer keyMu.RUnlock()
	return len(activeKey) == argonKeyLen
}

// GetActiveKey returns a copy of the current active key, or nil if locked.
// The snapshot package uses this to encrypt snapshot files with the vault key.
func GetActiveKey() []byte {
	keyMu.RLock()
	defer keyMu.RUnlock()
	if len(activeKey) != argonKeyLen {
		return nil
	}
	out := make([]byte, len(activeKey))
	copy(out, activeKey)
	return out
}

// Encrypt encrypts plaintext with the active session key using AES-256-GCM.
// Output format: base64(nonce + ciphertext + tag)
func Encrypt(plaintext string) (string, error) {
	keyMu.RLock()
	key := make([]byte, len(activeKey))
	copy(key, activeKey)
	keyMu.RUnlock()

	if len(key) == 0 {
		return "", errors.New("vault is locked")
	}
	return EncryptWithKey([]byte(plaintext), key)
}

// Decrypt decrypts ciphertext with the active session key.
func Decrypt(ciphertextB64 string) (string, error) {
	keyMu.RLock()
	key := make([]byte, len(activeKey))
	copy(key, activeKey)
	keyMu.RUnlock()

	if len(key) == 0 {
		return "", errors.New("vault is locked")
	}
	plain, err := DecryptWithKey(ciphertextB64, key)
	return string(plain), err
}

// EncryptWithKey encrypts plaintext bytes with the given key.
func EncryptWithKey(plaintext, key []byte) (string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	sealed := gcm.Seal(nonce, nonce, plaintext, nil)
	return base64.StdEncoding.EncodeToString(sealed), nil
}

// DecryptWithKey decrypts a base64-encoded ciphertext with the given key.
func DecryptWithKey(ciphertextB64 string, key []byte) ([]byte, error) {
	data, err := base64.StdEncoding.DecodeString(ciphertextB64)
	if err != nil {
		return nil, fmt.Errorf("base64 decode: %w", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(data) < gcm.NonceSize() {
		return nil, errors.New("ciphertext too short")
	}
	nonce, ciphertext := data[:gcm.NonceSize()], data[gcm.NonceSize():]
	return gcm.Open(nil, nonce, ciphertext, nil)
}

// RandomSecret generates a cryptographically random client secret (hex string).
func RandomSecret(bytes int) (string, error) {
	b := make([]byte, bytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
