package xray

import (
	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/format"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/proxy/vless"
)

func buildVlessUsers(tag string, userInfo []panel.UserInfo, flow string) (users []*protocol.User) {
	users = make([]*protocol.User, len(userInfo))
	for i := range userInfo {
		users[i] = buildVlessUser(tag, &(userInfo)[i], flow)
	}
	return users
}

func buildVlessUser(tag string, userInfo *panel.UserInfo, flow string) (user *protocol.User) {
	vlessAccount := &vless.Account{
		Id: userInfo.Uuid,
	}
	vlessAccount.Flow = flow
	return &protocol.User{
		Level:   0,
		Email:   format.UserTag(tag, userInfo.Uuid),
		Account: serial.ToTypedMessage(vlessAccount),
	}
}
