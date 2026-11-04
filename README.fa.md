# ServerTools

> ترجمهٔ فارسی — نسخهٔ مرجع انگلیسی است: [README.md](README.md)

**بهینه‌سازی سرور لینوکس بر اساس نقش — برای نود VPN، تانل و رله، و برای سرورهای معمولیِ کنارشان.**

با یک دستور تشخیص می‌دهد سرور *چه کاری* می‌کند — نود پروکسی، پنل، گیت‌وی وایرگارد، رلهٔ GRE، سرور Docker
با ربات، دیتابیس — و کرنل، کارت شبکه، مسیر فایروال و Docker را دقیقاً برای همان کار تنظیم می‌کند. هر تصمیم
دلیلش را می‌گوید، هر تغییر قابل برگشت است، و نتیجه بعد از ریبوت هم می‌ماند.

> نسخهٔ **2.4.6** · یک فایل bash · اجرا با root · Ubuntu 20.04+ / Debian 11+
> (توزیع‌های دیگر با apt، dnf/yum یا pacman معمولاً کار می‌کنند)

## نصب

```bash
bash <(curl -fsSL4 https://raw.githubusercontent.com/Sir-Adnan/server-tools/main/dist/server-tools.sh) --install
```

بعد `st` را اجرا کنید و **۱ (Quick Optimize)** را بزنید. به‌روزرسانی: `st --update`.
ابزارهای لازم (`ethtool`، `nftables`، `jq` و…) اگر نباشند خودکار نصب و روی صفحه اعلام می‌شوند؛ `--no-install`
این را خاموش می‌کند. سروری که با نسخهٔ قدیمی‌تر بهینه شده، در اولین اجرا ارتقا می‌یابد (ثبت‌شده و قابل برگشت).

## شروع سریع

```bash
st                      # منو → ۱ Quick Optimize
st --dry-run            # پلن، دلیل هر تصمیم، و diff دقیق — بدون هیچ تغییری
st --auto               # بدون سؤال: تشخیص و اعمال
st --diagnose           # اندازه‌گیری: softirq هر هسته، drop، صف‌ها، conntrack
st --verify             # هنوز اعمال است؟ (بعد از ریبوت بزنید)
st --rollback           # برگرداندن آخرین اجرا (دوباره = یک اجرا عقب‌تر)
```

## یک ابزار برای هر نوع سرور

| سرور | نقش تشخیص‌داده‌شده | چه چیزی بیشتر از لایهٔ پایه می‌گیرد |
| --- | --- | --- |
| x-ui / 3x-ui، نود Marzban / Pasarguard / Remnawave | `proxy` | fq + BBR، RPS/RFS روی کارت تک‌صف، conntrack بر اساس RAM |
| پنل با MySQL / PostgreSQL / Redis | `panel db` | تیر حداکثر M، نوشتن یکنواخت روی دیسک، overcommit برای Redis |
| ربات تلگرام یا سایت در Docker | `web db` + Docker | محدودیت حجم لاگ کانتینرها، live-restore، timeout مناسب conntrack |
| رلهٔ GRE / IPIP + DNAT | `tunnel relay` | fq_codel، RPS بدون هستهٔ وقفه، بدون RFS، MSS، پیشنهاد مسیر سریع |
| WireGuard / AmneziaWG / OpenVPN | `vpn` | UDP GRO forwarding، timeout طولانی‌تر NAT برای UDP، MSS |
| Backhaul / Rathole / gost / frp | `utunnel` | تنظیمات محلی + فوروارد، سقف فایل |
| رلهٔ HAProxy / nginx، ربات ساده | `web` / `general` | لایهٔ پایهٔ کامل |

نقش‌ها با هم ترکیب می‌شوند و می‌توانید تشخیص را دستی تعیین کنید: `st --auto --role relay,tunnel`.
جزئیات: [docs/ROLES.md](docs/ROLES.md).

## قابل اعتماد

- **بعد از ریبوت می‌ماند:** فایل sysctl بعد از `/etc/sysctl.conf` اعمال می‌شود، قوانین فایروال بعد از
  مدیرهای فایروال، DNS در مدیر شبکه پین می‌شود و خاموشی IPv6 روی هر کارت دوباره اعمال می‌شود — و اگر چیزی
  باز هم عوض شده باشد، `st --verify` و داشبورد اعلام می‌کنند.
- **قابل برگشت:** فایل‌ها، مقادیر زندهٔ `/sys`، کارت شبکه، qdisc، قوانین فایروال و ویرایش‌های `/etc/sysctl.conf`
  قبل از تغییر ثبت می‌شوند.
- **صادق:** هر مرحله OK / WARN / FAILED / SKIPPED گزارش می‌دهد و با سیستم واقعی مقایسه می‌شود.
- **سبک:** چند ثانیه اجرا می‌شود و هیچ سرویس دائمی‌ای نمی‌گذارد.
- **تست‌شده:** ShellCheck، حدود ۱۵۰ تست واحد، و تست روی کرنل واقعی با یک رلهٔ GRE + DNAT.

## مستندات

[راهنمای کامل](docs/GUIDE.fa.md) · [پرسش‌های متداول](docs/FAQ.fa.md) ·
[سرورهای تانل و رله](docs/TUNNELS.fa.md) · [تغییرات](CHANGELOG.md) — مستندات فنی به انگلیسی:
[نقش‌ها](docs/ROLES.md)، [تنظیمات کرنل](docs/SYSCTL.md)، [Rollback](docs/ROLLBACK.md)، [معماری](docs/ARCHITECTURE.md).

## سازنده

**UnknownZero** — تلگرام **@UnknownZero** · مجوز: [MIT](LICENSE)
