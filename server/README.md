# MRTRADER server

اپ ساده روی لینوکس. چند یوزر. هر یوزر سیستم خودش را با login / password / server آلپاری راه می‌اندازد.

## اجرا

```bash
cd mrtrader-server
echo SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))') > .env
echo ADMIN_USER=admin >> .env
echo ADMIN_PASS='یک رمز قوی' >> .env
docker compose up -d --build
```

باز کن: `http://IP-سرور:8080`

ادمین پیش‌فرض: `admin` / مقدار `ADMIN_PASS`

## کار ادمین

1. وارد شو
2. یوزر بساز (نام + رمز ورود به پنل)
3. همان را به دوست بده

## کار هر یوزر

1. وارد `/me` شود
2. Login و Password و Server آلپاری را بگذارد
3. راه‌اندازی سیستم

نمونه سرور دمو: `Alpari-MT5-Demo`

رمز آلپاری در دیتابیس رمزنگاری می‌شود. در لاگ نوشته نمی‌شود.

## نکته مهم معامله

کتابخانه رسمی MetaTrader5 فقط روی ویندوز کار می‌کند.
روی این سرور لینوکس، سیستم هر یوزر بالا می‌آید و اطلاعات را نگه می‌دارد.
سفارش واقعی خرید/فروش به ترمینال MT5 ویندوز نیاز دارد (یا یک Windows worker).

اگر سرور ویندوز شد، `pip install MetaTrader5` و متاتریدر را روی همان ماشین نصب کن؛ همین اپ وصل می‌شود.
