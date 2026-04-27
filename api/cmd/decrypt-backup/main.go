// AuthVault Backup Decryptor
//
// Downloads and/or decrypts encrypted backup files produced by authvault-api.
//
// Usage:
//   decrypt-backup -key <64-HEX-CHARS> <file.json.enc>
//
// The encryption key is a 32-byte (256-bit) AES key stored as 64 hex characters.
// It is printed once to the API log when the first S3 backup runs and is also
// stored in config.json under the "s3_backup_key" field.
//
// WARNING: Keep your key SAFE. Without it encrypted backups CANNOT be decrypted.
//
// Output: writes <file>.json next to the input file (strips the .enc extension).

package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"strings"
)

func main() {
	keyHex := flag.String("key", "", "Backup encryption key (64 hex characters / 32 bytes)")
	outPath := flag.String("out", "", "Output file path (default: strips .enc from input)")
	flag.Parse()

	if *keyHex == "" || flag.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "AuthVault Backup Decryptor")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "Usage:")
		fmt.Fprintln(os.Stderr, "  decrypt-backup -key <64-hex-key> <file.json.enc>")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "Options:")
		flag.PrintDefaults()
		os.Exit(1)
	}

	inFile := flag.Arg(0)
	keyBytes, err := hex.DecodeString(*keyHex)
	if err != nil || len(keyBytes) != 32 {
		fatalf("Invalid key — must be exactly 64 hex characters (32 bytes). Got: %s\n", *keyHex)
	}

	// Read ciphertext file
	cipherData, err := os.ReadFile(inFile)
	if err != nil {
		fatalf("Cannot read input file %q: %v\n", inFile, err)
	}

	// The file contains a base64-encoded AES-256-GCM blob (nonce + ciphertext + tag)
	plain, err := decryptWithKey(string(cipherData), keyBytes)
	if err != nil {
		fatalf("Decryption failed: %v\nDouble-check your key and that this file was produced by AuthVault.\n", err)
	}

	// Determine output path
	out := *outPath
	if out == "" {
		out = strings.TrimSuffix(inFile, ".enc")
		if out == inFile {
			out = inFile + ".decrypted"
		}
	}

	if err := os.WriteFile(out, plain, 0600); err != nil {
		fatalf("Cannot write output file %q: %v\n", out, err)
	}

	fmt.Printf("✓ Decrypted successfully → %s\n", out)
	fmt.Printf("  Input:  %s (%d bytes)\n", inFile, len(cipherData))
	fmt.Printf("  Output: %s (%d bytes)\n", out, len(plain))
}

// decryptWithKey decrypts a base64-encoded AES-256-GCM ciphertext.
func decryptWithKey(ciphertextB64 string, key []byte) ([]byte, error) {
	// Trim any whitespace (e.g. trailing newline in file)
	ciphertextB64 = strings.TrimSpace(ciphertextB64)

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
		return nil, fmt.Errorf("ciphertext too short")
	}
	nonce, ciphertext := data[:gcm.NonceSize()], data[gcm.NonceSize():]
	return gcm.Open(nil, nonce, ciphertext, nil)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "ERROR: "+format, args...)
	os.Exit(1)
}
