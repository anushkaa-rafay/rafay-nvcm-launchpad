"""lplib.py — helpers shared by the report's Python scripts (failure-mail.py, …). Standard library only.

  stage_section(workflow_log, stage)  one stage's section of a run's workflow.log, as scripts/lib-log.sh writes it
  send_mail(subject, html, files)     send through SMTP, configured by the environment (below)

Mail configuration, set by the workflow step from repository variables / secrets:
  MAIL_TO        comma-separated recipients — unset: nothing is sent (a notice, not an error)
  SMTP_USERNAME  the sending account (e.g. a Gmail address); also the From address
  SMTP_PASSWORD  its password — for Gmail an App Password, never the account password. A secret
  SMTP_SERVER    default smtp.gmail.com
  SMTP_PORT      default 465 (implicit TLS); 587 = STARTTLS; anything else = plain SMTP (local testing only)
"""
import os
import re
import smtplib
import ssl
import sys
from email.message import EmailMessage

ATTACH_GZIP_OVER = 5 * 1024 * 1024   # Gmail rejects a message over 25 MB; logs compress ~10x


def stage_section(workflow_log, stage):
    """The lines from `STAGE NN: <stage> (phase: …)` to its `STAGE STATUS:` line ([] if the stage isn't there)."""
    title = re.compile(r"^STAGE \d+: %s \(phase: [^)]*\)$" % re.escape(stage))
    out, inside = [], False
    try:
        with open(workflow_log, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                if not inside and title.match(line):
                    inside = True
                if inside:
                    out.append(line)
                    if line.startswith("STAGE STATUS:"):
                        break
    except FileNotFoundError:
        return []
    return out


def tail(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [l.rstrip("\n") for l in f.readlines()[-n:]]
    except FileNotFoundError:
        return []


def mail_configured():
    """True if send_mail would send; otherwise says why in the workflow log (a notice, never a failure)."""
    if not os.environ.get("MAIL_TO", "").strip():
        print("::notice::no mail sent — the MAIL_TO repository variable is not set")
        return False
    missing = [v for v in ("SMTP_USERNAME", "SMTP_PASSWORD") if not os.environ.get(v)]
    if missing:
        print("::warning::no mail sent — MAIL_TO is set but %s is not (SMTP_PASSWORD must be a secret)" % " and ".join(missing))
        return False
    return True


def send_mail(subject, html, files=()):
    """Send one HTML mail to MAIL_TO with `files` attached (files over 5 MB are gzipped). Raises on SMTP errors."""
    import gzip
    user = os.environ["SMTP_USERNAME"]
    to = [a.strip() for a in os.environ["MAIL_TO"].split(",") if a.strip()]
    server = os.environ.get("SMTP_SERVER") or "smtp.gmail.com"
    port = int(os.environ.get("SMTP_PORT") or 465)

    msg = EmailMessage()
    msg["Subject"], msg["From"], msg["To"] = subject, "NVCM Launchpad <%s>" % user, ", ".join(to)
    msg.set_content("This message is HTML; open it in a mail client that shows HTML.")
    msg.add_alternative(html, subtype="html")
    for path in files:
        if not os.path.isfile(path):
            continue
        name = os.path.basename(path)
        with open(path, "rb") as f:
            data = f.read()
        if len(data) > ATTACH_GZIP_OVER:
            data, name = gzip.compress(data), name + ".gz"
            msg.add_attachment(data, maintype="application", subtype="gzip", filename=name)
        else:
            msg.add_attachment(data, maintype="text", subtype="plain", filename=name)

    try:
        if port == 465:
            smtp = smtplib.SMTP_SSL(server, port, context=ssl.create_default_context(), timeout=60)
        else:
            smtp = smtplib.SMTP(server, port, timeout=60)
            if port == 587:
                smtp.starttls(context=ssl.create_default_context())
        with smtp:
            smtp.login(user, os.environ["SMTP_PASSWORD"])
            smtp.send_message(msg)
    except smtplib.SMTPAuthenticationError:
        fail("mail not sent: %s:%d refused the login for %s — for Gmail, SMTP_PASSWORD must be an App Password "
             "(Google Account → Security → App passwords), not the account password" % (server, port, user))
    except (OSError, smtplib.SMTPException) as e:
        fail("mail not sent via %s:%d: %s" % (server, port, e))
    print("mail sent to %d recipient(s): %s" % (len(to), subject))


def fail(message):
    print("::error::%s" % message)
    sys.exit(1)
