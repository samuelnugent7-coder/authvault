package handlers

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/smtp"
	"strings"
	"time"

	"authvault/api/internal/config"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
)

// GetEmailConfig handles GET /api/v1/email/config
func GetEmailConfig(w http.ResponseWriter, r *http.Request) {
	_, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		http.Error(w, `{"error":"admin only"}`, http.StatusForbidden)
		return
	}
	cfg := config.Get()
	ec := models.EmailConfig{
		Enabled:   cfg.EmailEnabled,
		Provider:  cfg.EmailProvider,
		SMTPHost:  cfg.EmailSMTPHost,
		SMTPPort:  cfg.EmailSMTPPort,
		SMTPUser:  cfg.EmailSMTPUser,
		SMTPTLS:   cfg.EmailSMTPTLS,
		SESKeyID:  cfg.EmailSESKeyID,
		SESRegion: cfg.EmailSESRegion,
		FromAddr:  cfg.EmailFrom,
		AlertTo:   cfg.EmailAlertTo,
		Triggers:  cfg.EmailTriggers,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(ec)
}

// UpdateEmailConfig handles PUT /api/v1/email/config
func UpdateEmailConfig(w http.ResponseWriter, r *http.Request) {
	_, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		http.Error(w, `{"error":"admin only"}`, http.StatusForbidden)
		return
	}
	var ec models.EmailConfig
	if err := json.NewDecoder(r.Body).Decode(&ec); err != nil {
		http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
		return
	}
	config.Update(func(c *config.Config) {
		c.EmailEnabled = ec.Enabled
		c.EmailProvider = ec.Provider
		c.EmailSMTPHost = ec.SMTPHost
		c.EmailSMTPPort = ec.SMTPPort
		c.EmailSMTPUser = ec.SMTPUser
		if ec.SMTPPass != "" {
			c.EmailSMTPPass = ec.SMTPPass
		}
		c.EmailSMTPTLS = ec.SMTPTLS
		c.EmailSESKeyID = ec.SESKeyID
		if ec.SESSecret != "" {
			c.EmailSESSecret = ec.SESSecret
		}
		c.EmailSESRegion = ec.SESRegion
		c.EmailFrom = ec.FromAddr
		c.EmailAlertTo = ec.AlertTo
		c.EmailTriggers = ec.Triggers
	})
	config.Save()
	w.WriteHeader(http.StatusNoContent)
}

// TestEmail handles POST /api/v1/email/test
func TestEmail(w http.ResponseWriter, r *http.Request) {
	_, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		http.Error(w, `{"error":"admin only"}`, http.StatusForbidden)
		return
	}
	cfg := config.Get()
	if !cfg.EmailEnabled {
		http.Error(w, `{"error":"email alerts not enabled"}`, http.StatusBadRequest)
		return
	}
	err := sendEmail(cfg, cfg.EmailAlertTo, "AuthVault Test Alert",
		"This is a test email from AuthVault sent at "+time.Now().UTC().Format(time.RFC3339))
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// SendAlertEmail is called internally for triggered alerts.
func SendAlertEmail(event, details string) {
	cfg := config.Get()
	if !cfg.EmailEnabled || cfg.EmailAlertTo == "" {
		return
	}
	// Check trigger list
	triggered := false
	for _, t := range cfg.EmailTriggers {
		if strings.EqualFold(t, event) || t == "*" {
			triggered = true
			break
		}
	}
	if !triggered {
		return
	}
	subject := "AuthVault Alert: " + event
	body := fmt.Sprintf("Event: %s\nDetails: %s\nTime: %s",
		event, details, time.Now().UTC().Format(time.RFC3339))
	go sendEmail(cfg, cfg.EmailAlertTo, subject, body)
}

func sendEmail(cfg *config.Config, to, subject, body string) error {
	if cfg.EmailProvider == "ses" {
		return sendSES(cfg, to, subject, body)
	}
	return sendSMTP(cfg, to, subject, body)
}

func sendSMTP(cfg *config.Config, to, subject, body string) error {
	addr := fmt.Sprintf("%s:%d", cfg.EmailSMTPHost, cfg.EmailSMTPPort)
	msg := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\n%s",
		cfg.EmailFrom, to, subject, body)

	if cfg.EmailSMTPTLS {
		tlsCfg := &tls.Config{ServerName: cfg.EmailSMTPHost, MinVersion: tls.VersionTLS12}
		conn, err := tls.Dial("tcp", addr, tlsCfg)
		if err != nil {
			return err
		}
		c, err := smtp.NewClient(conn, cfg.EmailSMTPHost)
		if err != nil {
			return err
		}
		defer c.Quit()
		if cfg.EmailSMTPUser != "" {
			auth := smtp.PlainAuth("", cfg.EmailSMTPUser, cfg.EmailSMTPPass, cfg.EmailSMTPHost)
			if err := c.Auth(auth); err != nil {
				return err
			}
		}
		if err := c.Mail(cfg.EmailFrom); err != nil {
			return err
		}
		if err := c.Rcpt(to); err != nil {
			return err
		}
		wc, err := c.Data()
		if err != nil {
			return err
		}
		defer wc.Close()
		_, err = fmt.Fprint(wc, msg)
		return err
	}

	// Plain STARTTLS path
	conn, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		return err
	}
	c, err := smtp.NewClient(conn, cfg.EmailSMTPHost)
	if err != nil {
		return err
	}
	defer c.Quit()
	if ok, _ := c.Extension("STARTTLS"); ok {
		tlsCfg := &tls.Config{ServerName: cfg.EmailSMTPHost, MinVersion: tls.VersionTLS12}
		if err := c.StartTLS(tlsCfg); err != nil {
			return err
		}
	}
	if cfg.EmailSMTPUser != "" {
		auth := smtp.PlainAuth("", cfg.EmailSMTPUser, cfg.EmailSMTPPass, cfg.EmailSMTPHost)
		if err := c.Auth(auth); err != nil {
			return err
		}
	}
	if err := c.Mail(cfg.EmailFrom); err != nil {
		return err
	}
	if err := c.Rcpt(to); err != nil {
		return err
	}
	wc, err := c.Data()
	if err != nil {
		return err
	}
	defer wc.Close()
	_, err = fmt.Fprint(wc, msg)
	return err
}

// sendSES sends via AWS SES SMTP endpoint (uses SMTP with SES credentials).
func sendSES(cfg *config.Config, to, subject, body string) error {
	// AWS SES SMTP: email-smtp.<region>.amazonaws.com:465 or 587
	host := fmt.Sprintf("email-smtp.%s.amazonaws.com", cfg.EmailSESRegion)
	addr := fmt.Sprintf("%s:587", host)
	msg := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\n%s",
		cfg.EmailFrom, to, subject, body)
	auth := smtp.PlainAuth("", cfg.EmailSESKeyID, cfg.EmailSESSecret, host)
	return smtp.SendMail(addr, auth, cfg.EmailFrom, []string{to}, []byte(msg))
}
