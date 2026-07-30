---
name: email-writing
description: Writing client-facing emails in Jappie's voice, result-first and not chatty. Use when drafting or editing any email, reply concept, or status update addressed to a client (reply-*.md concepts, offerte follow-ups, delivery announcements). Load BEFORE writing the draft, and apply when reviewing an existing draft.
---

# Client Email Writing

Distilled from Jappie's own cleanup of a drafted client mail (jappiesoft
`1f9378f`, "cleanup the email, less chatty"). The draft was correct and
complete; his edit cut it to less than half. Every cut followed the same
principle:

**The mail exists for the client's use and decisions, not as a work
log.** If a sentence serves us (justifies a choice, narrates process,
shows effort, relitigates a misunderstanding), it goes. Internal notes,
todo files and commit messages hold that material; the mail does not.

## Rules

1. **No banter or validation openers.** Cut "Haha, je hebt gelijk..."
   style acknowledgments, apologies for things already fixed, and
   restating what the client said. Open with the delivery: "Alles staat
   inmiddels online."
2. **One line per delivered item, result only.** "Ik heb het donkerblauw
   van je logo gebruikt." Not how it was measured, verified, or how
   close the match is. Method and caveats live in the internal notes.
3. **Fixed is fixed.** When the client can see the change on the site,
   don't explain the diagnosis or why the old version looked wrong.
   Delete the whole bullet if the result speaks for itself.
4. **Reference shared artifacts instead of describing them.** If the
   client gave the example, "Zelfde opzet als bij X" is complete; don't
   enumerate form fields or menu locations they can see by clicking.
5. **Actionable beats promissory.** Replace "dat lopen we door bij de
   overdracht" with the login URL and username so the client can act
   today.
6. **Secrets never in the mail body.** Passwords go through an expiring
   share link on veiligwachtwoorddelen.nl (expiry configurable per
   views or hours; set it tight); the mail carries only the link.
   Deliberate choice (Jappie, 2026-07-18): the service is not
   provably zero-knowledge, but it beats plaintext-in-mail, is not
   worth replacing with self-hosting, and the passwords we hand out
   are ugly generated ones the client is motivated to replace at
   handover, which caps the damage of any leak.
7. **Options carry their own trade-off.** Each option gets its price and
   a one-line pro/con inline. No separate "mijn advies"-paragraph; the
   list is the advice, the client chooses.
8. **Dependencies as facts, not deadline pressure.** "Zodra ik de
   teksten heb verwerk ik ze meteen, daarna kan de site live." Never
   "lukt het je om deze week..." conditionals.
9. **Few asks per mail.** Procedural logistics (account access, 2FA
   dances, scheduling) go via app or a call, not as an extra mail
   paragraph. Keep the asks the client actually has to think about.
10. **Close warm and short, at most one question.** "Kijk maar rustig
    rond, en hoor graag of het blauw zo klopt!"

## House style

Informal Dutch (je/jij), sign off with "Groet, Jappie". Never an
em-dash inside a sentence; use a comma, colon or parenthesis. Bullets
with `*emphasis*` labels for delivered items are fine.

## Before / after

Draft:

> Haha, je hebt gelijk, die kleur klopte niet! Ik heb de kleur van je
> logo nagemeten en die bleek op een onzichtbaar verschil na overeen te
> komen met de knopkleur, dus die gebruik ik nu overal. Je schreef dat
> je de codes eerder had gestuurd, maar die heb ik nergens ontvangen;
> stuur ze anders nog even als tekst. De teksten kun je straks zelf
> aanpassen, dat lopen we samen door bij de oplevering. Zou het je
> lukken de foto's deze week aan te leveren? Dan kan de site daarna
> live.

After cleanup:

> De kleuren van je logo staan er nu op. De teksten kun je zelf
> aanpassen; inloggen kan op https://voorbeeld.nl/wp-admin/ met
> gebruikersnaam anna, wachtwoord: [veiligwachtwoorddelen-link].
> Zodra ik de foto's heb zet ik ze erin, daarna kan de site live.
>
> Hoor graag of de kleuren zo kloppen!

## Review checklist

Before presenting a draft, walk the mail once and delete: every
sentence about our process, every justification, every restated client
statement, every future promise replaceable by a link, and every
question beyond the essential ones. If the mail still reads complete,
the cuts were correct.
