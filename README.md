# MRTRADER — MetaTrader 5 Expert Advisor (MQL5) and Server (legacy)

> Legacy MRTRADER project: MQL5 Expert Advisor for MetaTrader 5 plus a small FastAPI multi-user server. Earlier version of the 88 Trader project.

## 🌐 فارسی

پروژه قدیمی **MRTRADER**: اکسپرت (EA) به زبان **MQL5** برای متاتریدر ۵ به‌همراه یک سرور وب ساده FastAPI چندکاربره. نسخه قبلی پروژه ۸۸ تریدر.

**کلیدواژه‌ها:** اکسپرت MQL5، متاتریدر ۵، ربات فارکس، اکسپرت ادوایزر، FastAPI

## 🇬🇧 English

Legacy **MRTRADER** project: an **MQL5 Expert Advisor for MetaTrader 5** and a small FastAPI multi-user server (`server/`). It is the earlier version of the 88 Trader project. Demo accounts only; not financial advice.

**Keywords:** MQL5 Expert Advisor, MetaTrader 5 EA, forex trading robot, FastAPI server, algorithmic trading

## 🇷🇺 Русский

Устаревший проект **MRTRADER**: **советник (Expert Advisor) на MQL5 для MetaTrader 5** и небольшой многопользовательский сервер на FastAPI (`server/`). Ранняя версия проекта 88 Trader. Только демо-счета; не финансовая рекомендация.

**Ключевые слова:** советник MQL5, MetaTrader 5, торговый робот Forex, FastAPI

## 🇩🇪 Deutsch

Altes Projekt **MRTRADER**: ein **MQL5 Expert Advisor für MetaTrader 5** und ein kleiner FastAPI-Mehrbenutzerserver (`server/`). Frühe Version des Projekts 88 Trader. Nur Demokonten; keine Anlageberatung.

**Stichwörter:** MQL5 Expert Advisor, MetaTrader 5, Forex Handelsroboter, FastAPI

---

## Features

- `ea/MRTRADER.mq5` MQL5 Expert Advisor with install notes (`ea/package/`)
- `server/` FastAPI multi-user panel (Docker)

## Setup

```bash
# EA: copy ea/MRTRADER.mq5 to MQL5/Experts in your MT5 data folder and compile in MetaEditor.
# Server:
cd server && echo SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))') > .env
echo ADMIN_USER=admin >> .env && echo 'ADMIN_PASS=choose-a-strong-password' >> .env
docker compose up -d --build
```

## Usage

Open your bot in the messenger and send `/start`. See the detailed documentation below for commands, admin panel and platform-specific notes.

## License

Code released under the [MIT License](LICENSE).

---

## Detailed documentation

_See source code and inline comments._
