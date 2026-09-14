package store

// AISettings is the instance's single LLM access configuration (ADR-0009):
// one row for the whole instance, editable only by an administrator through
// the Web Console. The API key is stored in plaintext here — the instance
// database is the trust boundary — and masked by the API layer on its way
// out; it never round-trips to any client.

// AISettings is one snapshot of the instance's AI 设置.
type AISettings struct {
	BaseURL string
	Model   string
	APIKey  string
	Enabled bool
}

// AISettings returns the instance's configuration. The row is seeded by
// migration, so a missing row is a broken database, not a state to create.
func (s *Store) AISettings() (AISettings, error) {
	var set AISettings
	err := s.db.QueryRow(
		"SELECT base_url, model, api_key, enabled FROM ai_settings WHERE id = 1",
	).Scan(&set.BaseURL, &set.Model, &set.APIKey, &set.Enabled)
	return set, err
}

// SaveAISettings overwrites the instance's configuration. An empty APIKey
// keeps the stored one — the console sends a key only when the
// administrator typed a new one, so empty means "keep", never "clear".
func (s *Store) SaveAISettings(settings AISettings) error {
	q := "UPDATE ai_settings SET base_url = ?, model = ?, enabled = ?"
	args := []any{settings.BaseURL, settings.Model, settings.Enabled}
	if settings.APIKey != "" {
		q += ", api_key = ?"
		args = append(args, settings.APIKey)
	}
	q += " WHERE id = 1"
	_, err := s.db.Exec(q, args...)
	return err
}
