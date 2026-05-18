package conf

import (
	"encoding/json"
	"fmt"
)

type CoreConfig struct {
	Type       string      `json:"Type"`
	Name       string      `json:"Name"`
	XrayConfig *XrayConfig `json:"-"`
}

type _CoreConfig CoreConfig

func (c *CoreConfig) UnmarshalJSON(b []byte) error {
	err := json.Unmarshal(b, (*_CoreConfig)(c))
	if err != nil {
		return err
	}
	switch c.Type {
	case "xray", "":
		c.Type = "xray"
		c.XrayConfig = NewXrayConfig()
		return json.Unmarshal(b, c.XrayConfig)
	default:
		return fmt.Errorf("unsupported core type: %s, only xray is supported", c.Type)
	}
}
