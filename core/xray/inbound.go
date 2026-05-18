package xray

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"encoding/json"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	coreConf "github.com/xtls/xray-core/infra/conf"
)

// buildInbound 构建 VLESS 入站配置
func buildInbound(option *conf.Options, nodeInfo *panel.NodeInfo, tag string) (*core.InboundHandlerConfig, error) {
	in := &coreConf.InboundDetourConfig{}
	var err error
	var network string

	// 仅支持 vless 协议
	if nodeInfo.Type != "vless" {
		return nil, fmt.Errorf("unsupported node type: %s, Only support: vless", nodeInfo.Type)
	}

	err = buildVless(option, nodeInfo, in)
	network = nodeInfo.VAllss.Network

	if err != nil {
		return nil, err
	}

	// 设置服务器端口
	in.PortList = &coreConf.PortList{
		Range: []coreConf.PortRange{
			{
				From: uint32(nodeInfo.Common.ServerPort),
				To:   uint32(nodeInfo.Common.ServerPort),
			}},
	}

	// 设置监听 IP 地址
	ipAddress := net.ParseAddress(option.ListenIP)
	in.ListenOn = &coreConf.Address{Address: ipAddress}

	// 设置嗅探配置
	sniffingConfig := &coreConf.SniffingConfig{
		Enabled:      true,
		DestOverride: &coreConf.StringList{"http", "tls"},
	}
	if option.XrayOptions.DisableSniffing {
		sniffingConfig.Enabled = false
	}
	in.SniffingConfig = sniffingConfig

	// 设置网络协议
	if in.StreamSetting == nil {
		t := coreConf.TransportProtocol("tcp")
		in.StreamSetting = &coreConf.StreamConfig{Network: &t}
	}
	switch network {
	case "tcp":
		if in.StreamSetting.TCPSettings != nil {
			in.StreamSetting.TCPSettings.AcceptProxyProtocol = option.XrayOptions.EnableProxyProtocol
		} else {
			tcpSetting := &coreConf.TCPConfig{
				AcceptProxyProtocol: option.XrayOptions.EnableProxyProtocol,
			}
			in.StreamSetting.TCPSettings = tcpSetting
		}
	case "ws":
		if in.StreamSetting.WSSettings != nil {
			in.StreamSetting.WSSettings.AcceptProxyProtocol = option.XrayOptions.EnableProxyProtocol
		} else {
			in.StreamSetting.WSSettings = &coreConf.WebSocketConfig{
				AcceptProxyProtocol: option.XrayOptions.EnableProxyProtocol,
			}
		}
	default:
		if in.StreamSetting.SocketSettings == nil {
			in.StreamSetting.SocketSettings = &coreConf.SocketConfig{}
		}
		in.StreamSetting.SocketSettings.AcceptProxyProtocol = option.XrayOptions.EnableProxyProtocol
		in.StreamSetting.SocketSettings.TFO = option.XrayOptions.EnableTFO
	}

	// 设置 Reality 配置（仅支持 Reality）
	if nodeInfo.Security == panel.Reality {
		in.StreamSetting.Security = "reality"
		v := nodeInfo.VAllss
		dest := v.TlsSettings.Dest
		if dest == "" {
			dest = v.TlsSettings.ServerName
		}
		xver := v.TlsSettings.Xver
		if xver == 0 {
			xver = v.RealityConfig.Xver
		}
		d, err := json.Marshal(fmt.Sprintf(
			"%s:%s",
			dest,
			v.TlsSettings.ServerPort))
		if err != nil {
			return nil, fmt.Errorf("marshal reality dest error: %s", err)
		}
		mtd, _ := time.ParseDuration(v.RealityConfig.MaxTimeDiff)
		in.StreamSetting.REALITYSettings = &coreConf.REALITYConfig{
			Dest:         d,
			Xver:         xver,
			Show:         false,
			ServerNames:  []string{v.TlsSettings.ServerName},
			PrivateKey:   v.TlsSettings.PrivateKey,
			MinClientVer: v.RealityConfig.MinClientVer,
			MaxClientVer: v.RealityConfig.MaxClientVer,
			MaxTimeDiff:  uint64(mtd.Microseconds()),
			ShortIds:     []string{v.TlsSettings.ShortId},
			Mldsa65Seed:  v.TlsSettings.Mldsa65Seed,
		}
	}
	in.Tag = tag
	return in.Build()
}

func buildVless(config *conf.Options, nodeInfo *panel.NodeInfo, inbound *coreConf.InboundDetourConfig) error {
	v := nodeInfo.VAllss
	inbound.Protocol = "vless"

	if config.XrayOptions.EnableFallback {
		// 设置 fallback
		fallbackConfigs, err := buildVlessFallbacks(config.XrayOptions.FallBackConfigs)
		if err != nil {
			return err
		}
		s, err := json.Marshal(&coreConf.VLessInboundConfig{
			Decryption: "none",
			Fallbacks:  fallbackConfigs,
		})
		if err != nil {
			return fmt.Errorf("marshal vless fallback config error: %s", err)
		}
		inbound.Settings = (*json.RawMessage)(&s)
	} else {
		var err error
		decryption := "none"
		if nodeInfo.VAllss.Encryption != "" {
			switch nodeInfo.VAllss.Encryption {
			case "mlkem768x25519plus":
				encSettings := nodeInfo.VAllss.EncryptionSettings
				parts := []string{
					"mlkem768x25519plus",
					encSettings.Mode,
					encSettings.Ticket,
				}
				if encSettings.ServerPadding != "" {
					parts = append(parts, encSettings.ServerPadding)
				}
				parts = append(parts, encSettings.PrivateKey)
				decryption = strings.Join(parts, ".")
			default:
				return fmt.Errorf("vless decryption method %s is not support", nodeInfo.VAllss.Encryption)
			}
		}
		s, err := json.Marshal(&coreConf.VLessInboundConfig{
			Decryption: decryption,
		})
		if err != nil {
			return fmt.Errorf("marshal vless config error: %s", err)
		}
		inbound.Settings = (*json.RawMessage)(&s)
	}

	if len(v.NetworkSettings) == 0 {
		return nil
	}

	t := coreConf.TransportProtocol(v.Network)
	inbound.StreamSetting = &coreConf.StreamConfig{Network: &t}
	switch v.Network {
	case "tcp":
		err := json.Unmarshal(v.NetworkSettings, &inbound.StreamSetting.TCPSettings)
		if err != nil {
			return fmt.Errorf("unmarshal tcp settings error: %s", err)
		}
	case "ws":
		err := json.Unmarshal(v.NetworkSettings, &inbound.StreamSetting.WSSettings)
		if err != nil {
			return fmt.Errorf("unmarshal ws settings error: %s", err)
		}
	case "grpc":
		err := json.Unmarshal(v.NetworkSettings, &inbound.StreamSetting.GRPCSettings)
		if err != nil {
			return fmt.Errorf("unmarshal grpc settings error: %s", err)
		}
	case "httpupgrade":
		err := json.Unmarshal(v.NetworkSettings, &inbound.StreamSetting.HTTPUPGRADESettings)
		if err != nil {
			return fmt.Errorf("unmarshal httpupgrade settings error: %s", err)
		}
	case "splithttp", "xhttp":
		err := json.Unmarshal(v.NetworkSettings, &inbound.StreamSetting.SplitHTTPSettings)
		if err != nil {
			return fmt.Errorf("unmarshal xhttp settings error: %s", err)
		}
	default:
		return errors.New("the network type is not vail")
	}
	return nil
}

func buildVlessFallbacks(fallbackConfigs []conf.FallBackConfigForXray) ([]*coreConf.VLessInboundFallback, error) {
	if fallbackConfigs == nil {
		return nil, fmt.Errorf("you must provide FallBackConfigs")
	}
	vlessFallBacks := make([]*coreConf.VLessInboundFallback, len(fallbackConfigs))
	for i, c := range fallbackConfigs {
		if c.Dest == "" {
			return nil, fmt.Errorf("dest is required for fallback fialed")
		}
		var dest json.RawMessage
		dest, err := json.Marshal(c.Dest)
		if err != nil {
			return nil, fmt.Errorf("marshal dest %s config fialed: %s", dest, err)
		}
		vlessFallBacks[i] = &coreConf.VLessInboundFallback{
			Name: c.SNI,
			Alpn: c.Alpn,
			Path: c.Path,
			Dest: dest,
			Xver: c.ProxyProtocolVer,
		}
	}
	return vlessFallBacks, nil
}
