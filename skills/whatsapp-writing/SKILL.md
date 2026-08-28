---
name: whatsapp-writing
description: Writing client-facing WhatsApp messages in Jappie's voice. Use when drafting or editing any app/WhatsApp bericht to a client (urgent updates, quick asks, delivery pings), and when recording a sent app message in a project. Load BEFORE writing the draft; for the underlying voice rules also load email-writing.
---

# Client WhatsApp Writing

WhatsApp is the urgent, short channel: livegang pings, quick asks,
one-line deliveries. Everything in the email-writing skill about
voice applies here too (result first, no banter, few asks, informal
je/jij Dutch); load that skill alongside this one. This file covers
only what is different on the app channel. Distilled from the
waardegebaar livegang round (28 aug 2026, jappiesoft PR #249).

## Channel rules

1. No aanhef and no ondertekening. It is chat: the name is on the
   screen, "Groet, Jappie" reads as a pasted mail.
2. One topic per block, blocks separated by a blank line, so Jappie
   can send them as individual messages. Two blocks is the normal
   maximum; if you need three, reconsider the channel (mail).
3. Even terser than mail. A block is one to three sentences. If a
   block needs a bullet list, it belongs in a mail, not in the app.
4. An ask carries its own reason in the same sentence, so the client
   knows what it unlocks: "Kun je me de inlog van team@ sturen via
   veiligwachtwoorddelen.nl? Dan stel ik de mailkoppeling in, zodat
   de berichten in die mailbox binnenkomen."
5. One expectation-management sentence is allowed when the client
   will otherwise think something is broken ("Het kan even duren
   voor je browser het oude icoontje loslaat").
6. Passwords and logins never travel in the chat text, in either
   direction. Sending: veiligwachtwoorddelen.nl link (see the
   email-writing skill for the rationale). Asking: request the
   client sends theirs via veiligwachtwoorddelen.nl, named
   explicitly in the ask.
7. No emoji unless Jappie dictated them.

## From dictation to draft

Jappie usually dictates the message as an English paraphrase in
chat ("I suppose we just say: hey we did the favicon thing ...").
The deliverable is the Dutch client-facing text in his voice:

- Keep his structure and content decisions; they are the message.
  Do not re-add things he left out or soften his asks.
- Translate to informal Dutch, not literally: "oh btw we tested
  the mail forms" became "We hebben trouwens de formulieren op de
  site getest".
- Fix evident typos in addresses, domains and names against the
  project notes, and tell Jappie you did (les 28 aug:
  "team@waardebaar.nl" in the dictation, team@hetwaardegebaar.nl
  in the draft).
- Print the finished text in chat as a quoted block so he can copy
  it straight into WhatsApp.

## Record-keeping

Same conventions as mail concepts (see the jappie-software
CLAUDE.md), with the channel named:

- Concept lives in =projects/<klant>/reply-<datum>-<onderwerp>.md=;
  the header notes "Kanaal is WhatsApp, dus geen aanhef of
  ondertekening", the sendable text sits below the =---=.
- Status CONCEPT until Jappie says it went out, then VERSTUURD with
  the date and "tekst per concept" (he edits while sending; never
  claim a verbatim copy). After sending, note whose move it is
  ("bal bij ...").
- Client messages received via WhatsApp are quoted verbatim in the
  project todo or notes, like a mail in emails.md would be; the
  thread has no other archive we control.
