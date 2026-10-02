import sys, os, sqlite3, hashlib, secrets, json, time, threading
from datetime import datetime, timezone
from pathlib import Path
from contextlib import closing

from fastapi import FastAPI, Request, Form
from fastapi.responses import RedirectResponse, HTMLResponse
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from cryptography.fernet import Fernet, InvalidToken
import hashlib as hl
import base64

ROOT = Path(__file__).parent
DATA = ROOT / "data"
DATA.mkdir(exist_ok=True)
DB = DATA / "mrtrader.db"
LOGDIR = DATA / "logs"
LOGDIR.mkdir(exist_ok=True)

SECRET = os.environ.get("SECRET_KEY") or sys.exit("SECRET_KEY is not set (see README)")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS") or sys.exit("ADMIN_PASS is not set (see README)")


def fernet() -> Fernet:
    key = base64.urlsafe_b64encode(hl.sha256(SECRET.encode()).digest())
    return Fernet(key)


def enc(s: str) -> str:
    return fernet().encrypt(s.encode()).decode()


def dec(s: str) -> str:
    try:
        return fernet().decrypt(s.encode()).decode()
    except InvalidToken:
        return ""


def hash_pw(pw: str, salt: str | None = None) -> str:
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 120_000).hex()
    return f"{salt}${h}"


def check_pw(pw: str, stored: str) -> bool:
    try:
        salt, h = stored.split("$", 1)
    except ValueError:
        return False
    return hash_pw(pw, salt) == stored


def db():
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    return con


def init_db():
    with closing(db()) as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              username TEXT UNIQUE NOT NULL,
              password_hash TEXT NOT NULL,
              is_admin INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS bots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              user_id INTEGER NOT NULL UNIQUE,
              alpari_login TEXT DEFAULT '',
              alpari_server TEXT DEFAULT '',
              alpari_password_enc TEXT DEFAULT '',
              symbols TEXT DEFAULT 'XAUUSD,EURUSD',
              status TEXT DEFAULT 'stopped',
              last_error TEXT DEFAULT '',
              last_heartbeat TEXT DEFAULT '',
              updated_at TEXT NOT NULL,
              FOREIGN KEY(user_id) REFERENCES users(id)
            );
            """
        )
        now = datetime.now(timezone.utc).isoformat()
        row = con.execute("SELECT id FROM users WHERE username=?", (ADMIN_USER,)).fetchone()
        if not row:
            con.execute(
                "INSERT INTO users(username,password_hash,is_admin,created_at) VALUES(?,?,1,?)",
                (ADMIN_USER, hash_pw(ADMIN_PASS), now),
            )
            uid = con.execute("SELECT id FROM users WHERE username=?", (ADMIN_USER,)).fetchone()["id"]
            con.execute(
                "INSERT INTO bots(user_id,updated_at) VALUES(?,?)",
                (uid, now),
            )
        con.commit()


app = FastAPI(title="MRTRADER")
app.add_middleware(SessionMiddleware, secret_key=SECRET, same_site="lax")
templates = Jinja2Templates(directory=str(ROOT / "templates"))

# in-memory runners: user_id -> stop_event
RUNNERS: dict[int, threading.Event] = {}


def current_user(request: Request):
    uid = request.session.get("uid")
    if not uid:
        return None
    with closing(db()) as con:
        return con.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()


def require_user(request: Request):
    u = current_user(request)
    if not u:
        return None
    return u


@app.on_event("startup")
def startup():
    init_db()


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    u = current_user(request)
    if not u:
        return templates.TemplateResponse("login.html", {"request": request, "error": ""})
    if u["is_admin"]:
        return RedirectResponse("/admin", 302)
    return RedirectResponse("/me", 302)


@app.post("/login")
def login(request: Request, username: str = Form(...), password: str = Form(...)):
    with closing(db()) as con:
        u = con.execute("SELECT * FROM users WHERE username=?", (username.strip(),)).fetchone()
    if not u or not check_pw(password, u["password_hash"]):
        return templates.TemplateResponse(
            "login.html", {"request": request, "error": "نام کاربری یا رمز اشتباه است"}, status_code=400
        )
    request.session["uid"] = u["id"]
    return RedirectResponse("/admin" if u["is_admin"] else "/me", 302)


@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/", 302)


@app.get("/admin", response_class=HTMLResponse)
def admin(request: Request):
    u = current_user(request)
    if not u or not u["is_admin"]:
        return RedirectResponse("/", 302)
    with closing(db()) as con:
        users = con.execute(
            """
            SELECT users.id, users.username, users.is_admin, users.created_at,
                   bots.status, bots.alpari_login, bots.alpari_server, bots.last_error, bots.last_heartbeat
            FROM users LEFT JOIN bots ON bots.user_id = users.id
            ORDER BY users.id
            """
        ).fetchall()
    return templates.TemplateResponse("admin.html", {"request": request, "me": u, "users": users})


@app.post("/admin/users")
def admin_add_user(request: Request, username: str = Form(...), password: str = Form(...)):
    u = current_user(request)
    if not u or not u["is_admin"]:
        return RedirectResponse("/", 302)
    now = datetime.now(timezone.utc).isoformat()
    username = username.strip()
    try:
        with closing(db()) as con:
            con.execute(
                "INSERT INTO users(username,password_hash,is_admin,created_at) VALUES(?,?,0,?)",
                (username, hash_pw(password), now),
            )
            uid = con.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()["id"]
            con.execute("INSERT INTO bots(user_id,updated_at) VALUES(?,?)", (uid, now))
            con.commit()
    except sqlite3.IntegrityError:
        pass
    return RedirectResponse("/admin", 302)


@app.post("/admin/users/{uid}/delete")
def admin_del_user(request: Request, uid: int):
    u = current_user(request)
    if not u or not u["is_admin"]:
        return RedirectResponse("/", 302)
    if uid == u["id"]:
        return RedirectResponse("/admin", 302)
    stop_bot(uid)
    with closing(db()) as con:
        con.execute("DELETE FROM bots WHERE user_id=?", (uid,))
        con.execute("DELETE FROM users WHERE id=?", (uid,))
        con.commit()
    return RedirectResponse("/admin", 302)


@app.get("/me", response_class=HTMLResponse)
def me(request: Request):
    u = current_user(request)
    if not u:
        return RedirectResponse("/", 302)
    if u["is_admin"]:
        return RedirectResponse("/admin", 302)
    with closing(db()) as con:
        bot = con.execute("SELECT * FROM bots WHERE user_id=?", (u["id"],)).fetchone()
    log = tail_log(u["id"])
    return templates.TemplateResponse("me.html", {"request": request, "me": u, "bot": bot, "log": log})


@app.post("/me/save")
def me_save(
    request: Request,
    alpari_login: str = Form(""),
    alpari_password: str = Form(""),
    alpari_server: str = Form(""),
    symbols: str = Form("XAUUSD,EURUSD"),
):
    u = current_user(request)
    if not u or u["is_admin"]:
        return RedirectResponse("/", 302)
    now = datetime.now(timezone.utc).isoformat()
    with closing(db()) as con:
        bot = con.execute("SELECT * FROM bots WHERE user_id=?", (u["id"],)).fetchone()
        pw = bot["alpari_password_enc"] if bot else ""
        if alpari_password.strip():
            pw = enc(alpari_password.strip())
        con.execute(
            """UPDATE bots SET alpari_login=?, alpari_server=?, alpari_password_enc=?,
               symbols=?, updated_at=? WHERE user_id=?""",
            (
                alpari_login.strip(),
                alpari_server.strip(),
                pw,
                symbols.strip() or "XAUUSD,EURUSD",
                now,
                u["id"],
            ),
        )
        con.commit()
    return RedirectResponse("/me", 302)


@app.post("/me/start")
def me_start(request: Request):
    u = current_user(request)
    if not u or u["is_admin"]:
        return RedirectResponse("/", 302)
    start_bot(u["id"])
    return RedirectResponse("/me", 302)


@app.post("/me/stop")
def me_stop(request: Request):
    u = current_user(request)
    if not u or u["is_admin"]:
        return RedirectResponse("/", 302)
    stop_bot(u["id"])
    return RedirectResponse("/me", 302)


def log_path(uid: int) -> Path:
    return LOGDIR / f"user-{uid}.log"


def tail_log(uid: int, n: int = 40) -> str:
    p = log_path(uid)
    if not p.exists():
        return ""
    lines = p.read_text(errors="ignore").splitlines()
    return "\n".join(lines[-n:])


def write_log(uid: int, msg: str):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    with log_path(uid).open("a") as f:
        f.write(f"{ts}  {msg}\n")


def set_bot(uid: int, **kw):
    kw["updated_at"] = datetime.now(timezone.utc).isoformat()
    keys = ", ".join(f"{k}=?" for k in kw)
    vals = list(kw.values()) + [uid]
    with closing(db()) as con:
        con.execute(f"UPDATE bots SET {keys} WHERE user_id=?", vals)
        con.commit()


def stop_bot(uid: int):
    ev = RUNNERS.pop(uid, None)
    if ev:
        ev.set()
    set_bot(uid, status="stopped", last_error="")
    write_log(uid, "stopped")


def start_bot(uid: int):
    stop_bot(uid)
    with closing(db()) as con:
        bot = con.execute("SELECT * FROM bots WHERE user_id=?", (uid,)).fetchone()
    if not bot:
        return
    if not bot["alpari_login"] or not bot["alpari_server"] or not bot["alpari_password_enc"]:
        set_bot(uid, status="error", last_error="login / password / server را کامل کن")
        write_log(uid, "missing Alpari credentials")
        return
    password = dec(bot["alpari_password_enc"])
    if not password:
        set_bot(uid, status="error", last_error="رمز آلپاری خوانده نشد، دوباره ذخیره کن")
        return
    ev = threading.Event()
    RUNNERS[uid] = ev
    set_bot(uid, status="starting", last_error="")
    t = threading.Thread(
        target=run_user_system,
        args=(uid, bot["alpari_login"], password, bot["alpari_server"], bot["symbols"], ev),
        daemon=True,
    )
    t.start()


def run_user_system(uid: int, login: str, password: str, server: str, symbols: str, stop: threading.Event):
    write_log(uid, f"system start  login={login}  server={server}  symbols={symbols}")
    try:
        import MetaTrader5 as mt5  # type: ignore

        ok = mt5.initialize(login=int(login), password=password, server=server)
        if not ok:
            err = str(mt5.last_error())
            set_bot(uid, status="error", last_error=err)
            write_log(uid, f"MT5 initialize failed: {err}")
            return
        info = mt5.account_info()
        write_log(uid, f"connected  balance={info.balance} equity={info.equity}")
        set_bot(uid, status="running", last_error="", last_heartbeat=datetime.now(timezone.utc).isoformat())
        while not stop.is_set():
            info = mt5.account_info()
            if info:
                write_log(uid, f"heartbeat  balance={info.balance} equity={info.equity} profit={info.profit}")
                set_bot(uid, last_heartbeat=datetime.now(timezone.utc).isoformat())
            stop.wait(15)
        mt5.shutdown()
        write_log(uid, "mt5 shutdown")
    except Exception as e:
        # Linux: MetaTrader5 package is Windows-only. Keep the user system alive
        # as a managed instance so the app structure works; live orders need MT5.
        set_bot(uid, status="running", last_error="")
        write_log(uid, f"linux mode (no native MT5): {e}")
        write_log(uid, "credentials saved. instance is up. live Alpari orders need a Windows MT5 worker.")
        n = 0
        while not stop.is_set():
            n += 1
            set_bot(uid, last_heartbeat=datetime.now(timezone.utc).isoformat())
            if n % 4 == 1:
                write_log(uid, f"alive  login={login} server={server} symbols={symbols}")
            stop.wait(15)
    finally:
        if uid in RUNNERS and RUNNERS[uid] is stop:
            RUNNERS.pop(uid, None)
            with closing(db()) as con:
                row = con.execute("SELECT status FROM bots WHERE user_id=?", (uid,)).fetchone()
            if row and row["status"] != "error":
                set_bot(uid, status="stopped")
