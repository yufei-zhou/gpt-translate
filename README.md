# GPT Translate

A background macOS app. Press ⌘C C to translate the selection into two languages with the OpenAI API, shown in a floating panel.

- zh → en, fr · en → zh, fr · fr → en, zh · other → en, zh
- With nothing selected, ⌘C C translates a clipboard copy made in the last 5 minutes that hasn't been used yet; otherwise it reopens the panel as you left it. ⌘N clears it.
- The API key is stored in the Keychain.

## 安装 / 更新

在终端运行（安装和更新都是这一行）：

```bash
curl -fsSL https://raw.githubusercontent.com/yufei-zhou/gpt-translate/main/install.sh | bash
```

第一次打开时：

1. 按提示在「系统设置 → 隐私与安全性 → 输入监控」里允许 GPT Translate，⌘C C 才能用。
2. 在设置窗口里填入 OpenAI API Key。

以后更新时这两项都会保留。更新后第一次打开时，系统可能要求输入电脑密码来读取钥匙串里的 Key，输入后点「始终允许」即可，直到下次更新都不会再问。

## 卸载

```bash
pkill -x GPTTranslate; rm -rf "/Applications/GPT Translate.app"
```

## Build

```bash
./build.sh
```

Requires the Xcode command-line tools. `./release.sh X.Y.Z "notes"` publishes a signed release.
