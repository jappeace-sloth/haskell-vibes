---
name: email-writing
description: Write and review client-facing emails in Jappie's voice, especially replies. Use when drafting or editing emails, reply concepts, offerte follow-ups or delivery announcements, and when comparing a draft against the client's questions. Load BEFORE writing or reviewing the draft.
---

# Client Email Writing

Distilled from Jappie's own cleanup of a drafted client mail (jappiesoft
`1f9378f`, "cleanup the email, less chatty"). The draft was correct and
complete; his edit cut it to less than half. Every cut followed the same
principle:

The mail exists for the client's use and decisions, not as a work log.
Cut process narration, demonstrations of effort and internal commercial
reasoning. Keep a short explanation when the client needs it to understand
an answer, a scope boundary or a changed offer.

## Start with the incoming email

Most emails are replies. Read the actual incoming message before editing
the existing draft: a polished draft can still answer the wrong question.
For a disputed scope or price, also read the quotation, relevant sent
messages and Jappie's latest decisions. An old draft is not proof of what
was sent, and silence is not acceptance.

Ultrathink privately about ambiguous scope and commitments, not in the
client's inbox. Make a small internal coverage list:

1. Separate questions, requests, objections and status updates. Split
   compound questions: "where is this used, in links or in Google?" has
   more than one part. A status update need not receive its own paragraph.
2. Match each actionable point to a direct answer, a verified result or
   a clearly stated open dependency. Mark unknowns instead of inventing
   certainty. Distinguish approved work, deployed work and verified work.
3. Answer the practical choice behind the wording. "The photo boxes now
   match" does not fully answer "must I edit my images?" Add "De
   afbeeldingen zelf hoeven jullie niet aan te passen."
4. Group related answers into a short reply. Use headings when needed,
   not one paragraph per sentence of the incoming mail. Open with the
   main answer or result, then the necessary decisions and actions.

Keep the coverage list internal unless Jappie asks for a comparison.
After editing, compare against the incoming message again, not just the
previous draft. Be concise by removing distractions, not unanswered parts.

## Keep internal reasoning out of the reply

Distilled from the CanyonZone reply review (jappiesoft #483, 8 October 2026):

- Do not reopen pricing, concessions or old sales pressure just because
  the history mentions them. A request to delay can need only a new
  expected date, not an unsolicited reassurance about price. Include
  material costs or dependencies when a decision actually requires them;
  agree new charges before work, never conceal them.
- A client's useful QA may justify flexibility internally. Do not explain
  that they improve our program unless it serves their question. It can
  make a migration sound like a tooling test. Do not prescribe how their
  colleagues divide review or assert that someone need not inspect their
  own shop.
- Separate corrections, disputed existing behaviour and new capabilities.
  Never make a scope concession or waive a quoted fee without Jappie's
  approval. Once approved, state its exact extent and whether it replaces
  an earlier offer. Approval alone is not deployment or verification.
- Answer a blanket scope objection briefly rather than ignoring it or
  accepting it through silence. Refer to the written scope, not "we never
  promised" when the client refers to a conversation we cannot verify.
  A specific concession need not imply all existing functionality is free.
- Explain alternatives through the client's workload and outcome, not
  whether we need a theme edit or app. A cheaper business-order marker can
  leave prices and follow-up manual; account-based pricing can reduce that
  work. Do not disparage their existing process or invent a cheaper price.
- Verify platform claims at primary sources and qualify their limits.
  Minimum quantities per variant are not a minimum order value. Separate
  current usage from planned usage and stored data from fields copied into
  another system. Avoid absolutes such as "used nowhere" when an approved
  change will use it.
- When asked to consolidate outstanding offers, list only relevant prior
  offers without a recorded decision. Include price, recurring cost and
  what remains without the upgrade. "Wel, niet of later" makes the choice
  easy. Do not reintroduce resolved items or imply an unsent draft was
  received. Keep optional upgrades separate from migration corrections.

For an approved concession, a short boundary and reason can be useful:

> De offerte omvat het overzetten van de gegevens en pagina's en het zo
> goed mogelijk nabootsen van het uiterlijk, niet het één-op-één overnemen
> van alle functies. De levertijd bij uitverkochte artikelen neem ik na
> heroverweging wel zonder extra kosten mee, omdat die informatie bij het
> bestellen hoort. Het eerdere aanbod van €150 vervalt daarmee.

This is an example of a specific approved decision, not a standard policy
to include delivery-time work for free.

## Rules

1. Avoid banter or validation openers. Cut "Haha, je hebt gelijk..."
   style acknowledgments, apologies for things already fixed, and
   restating what the client said. Open with the answer or verified
   delivery: "Een latere livegang kan" or "Alles staat inmiddels online."
2. Give one line per delivered item, result only. "Ik heb het donkerblauw
   van je logo gebruikt." Not how it was measured, verified, or how
   close the match is. Diagnostic detail stays in internal notes; keep
   limitations that affect the client's decision in the reply.
3. Fixed is fixed. When the client can see the change on the site,
   don't explain the diagnosis or why the old version looked wrong.
   Delete the whole bullet only if no client question is left unanswered.
4. Reference shared artifacts instead of describing them. If the
   client gave the example, "Zelfde opzet als bij X" can be enough if it
   answers their question. Don't enumerate form fields or menu locations
   they can see by clicking.
5. Prefer actionable instructions to vague promises. Replace "dat lopen we door bij de
   overdracht" with the login URL and username so the client can act
   today.
6. Never put secrets in the mail body. Passwords go through an expiring
   share link on veiligwachtwoorddelen.nl (expiry configurable per
   views or hours; set it tight); the mail carries only the link.
   Deliberate choice (Jappie, 2026-07-18): the service is not
   provably zero-knowledge, but it beats plaintext-in-mail, is not
   worth replacing with self-hosting, and the passwords we hand out
   are ugly generated ones the client is motivated to replace at
   handover, which caps the damage of any leak.
7. Give options their own trade-off. Each option gets its approved price and
   a one-line pro/con inline. No separate "mijn advies"-paragraph; the
   list is the advice, the client chooses.
8. State dependencies as facts, not deadline pressure. "Zodra ik de
   teksten heb verwerk ik ze meteen, daarna kan de site live." Never
   "lukt het je om deze week..." conditionals.
9. Keep asks few. Procedural logistics (account access, 2FA
   dances, scheduling) go via app or a call, not as an extra mail
   paragraph, unless needed to answer the client's question. Bundle the
   decisions the client actually has to make.
10. Close warm and short, at most one question. "Kijk maar rustig
    rond, en hoor graag of het blauw zo klopt!"

## House style

Informal Dutch (je/jij), sign off with "Groet, Jappie". Never an
em-dash inside a sentence; use a comma, colon or parenthesis. Do not open
paragraphs or bullets with bold or italic topic labels; use real headings
for grouping.

## Two files per draft

Write every draft as two files side by side in the client's project:

- `reply-<naam>-<datum>-<onderwerp>.md` holds only the mail, from the
  greeting to "Groet, Jappie". No title, status, separator or notes.
- `reply-<naam>-<datum>-<onderwerp>.notes.md` holds everything else:
  send status (CONCEPT or verstuurd, with date), recipient, the subject
  line ("Onderwerp: Re: ..."), attachments and internal notes, plus a
  link to the draft.

Assume Jappie sends the mail tired or in a bad state of mind. Select all
and copy in the draft file must yield exactly the mail, so a fat-fingered
selection cannot leak internal reasoning, unapproved prices or client data
into the client's inbox. A `---` separator in one file still depends on a
careful selection, which is why it was replaced (Jappie, 8 October 2026).
The subject lives in the notes because it is pasted into its own field.

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

Before presenting a draft:

- Compare it point by point with the incoming email. Cover every actionable
  question and objection, including the parts inside compound questions.
- Remove internal process, sales reasoning, unnecessary repetition and
  extra asks. Retain short explanations needed for scope or decisions.
- Check prices and concessions against Jappie's approval. Check done-form
  against execution and verification, not merely permission or a report
  that something was connected. Keep unknown send status explicit internally.
- Check that practical consequences are explicit: must the client do
  anything, what remains manual, and what is still pending?
- Check that the draft file starts at the greeting and ends at the sign-off,
  and that subject, status and notes sit in the `.notes.md` file.
- If Jappie asks for a review, report gaps without silently editing. If
  he approves an edit, change the canonical draft, not just a chat example.
  In the handoff distinguish proposed wording, saved edits and sent mail.
