**Immigroov**

Booking Lifecycle - Developer Overview

Internal reference · June 2026

**Overview**

A booking is created the moment a customer pays for a package and selects a session slot. From that point, the booking can move through three event paths: cancel, reschedule, or no-show. Every path has rules depending on who initiates the action and whether it falls within the 24-hour deadline before the session.

_Key rule: the deadline is 24 hours before session start. Within deadline = free action. Past deadline = approval required or penalty applies._

**Cancel Flow**

**Customer cancels**

• Within 24 hrs of session: customer picks a new slot directly. No penalty.

• Past 24 hrs: a cancellation request is sent to the mentor.

• If mentor accepts (or does not respond within the response window): customer picks a new slot. No penalty.

• If mentor rejects: customer pays 50% of the session fee. Booking is cancelled.

**Mentor cancels**

• Within 24 hrs of session: no penalty. Booking cancelled. Customer notified with rebook option.

• Past 24 hrs: mentor sees a warning. A 25% penalty is deducted from their payout. Booking cancelled. Customer refunded.

**Reschedule Flow**

Maximum 2 reschedules per booking. A third attempt by either party triggers auto-cancellation, full refund to customer, and 100% penalty on whoever initiated the third attempt.

**Customer reschedules**

• Within 24 hrs of session: customer picks a new slot directly. Auto-confirmed.

• Past 24 hrs: request sent to mentor. Mentor must respond within the response window.

• Mentor accepts or does not reply: customer picks new slot. Auto-confirmed.

• Mentor rejects: customer pays 50% to cancel, or keeps the original booking.

**Mentor reschedules**

• Mentor proposes new slots from their existing calendar or a new date/time range.

• System notifies mentor whether the proposal is within or past the 24-hour deadline.

• Within 24 hrs: no penalty flagged. Customer receives the proposal.

• Past 24 hrs: a 25% penalty warning is shown to the mentor before they confirm.

• Customer accepts: booking auto-confirmed. New emails and .ics sent to both.

• Customer does not respond within the window: original booking reinstated. No penalty.

• Customer rejects a within-deadline proposal: customer receives a credit for a future booking. No cash refund.

• Customer rejects a past-deadline proposal: customer receives a full cash refund. Penalty applied to mentor.

_Response window formula: MIN(48 hours from proposal, session start minus 2 hours). If less than 2 hours remain before the session, any reschedule or cancel request is blocked and treated as a no-show._

**No-Show Handling**

If neither party has joined the session link within 10 minutes of start time, the system automatically flags a no-show and notifies both parties.

**Mentor no-shows - customer gets 3 choices**

• Rebook with the same mentor: reschedule cycle starts. Penalty on mentor is waived.

• Rebook with a different mentor: a new mentor shortlist is shown. Penalty applied to original mentor.

• Request a full refund: refund issued immediately. Penalty applied to mentor.

**Customer no-shows - mentor gets 2 choices**

• Accept rebook: the standard reschedule cycle begins. Mentor proposes new slots.

• Reject rebook: session is marked complete. Mentor is paid in full. No refund to customer.

**Mentor no-show strike system**

• Strike 1 and 2: warning only. No financial penalty.

• Strike 2 also triggers an internal Immigroov ops check-in with the mentor.

• Strike 3 and beyond: 25% penalty deducted per no-show session.

• Strikes reset automatically after 90 consecutive days with zero no-shows.

**Quick Reference - Key Rules**

| **Rule**                                       | Value                                                       |
| ---------------------------------------------- | ----------------------------------------------------------- |
| **Session deadline**                           | 24 hours before session start                               |
| **Response window**                            | MIN(48 hrs from proposal, session start − 2 hrs)            |
| **Session buffer**                             | Actions blocked if less than 2 hrs remain before session    |
| **Reschedule cap**                             | Max 2 per booking. 3rd attempt = auto-cancel + 100% penalty |
| **Customer past-deadline cancel (rejected)**   | 50% of session fee charged to customer                      |
| **Mentor past-deadline cancel**                | 25% of session fee deducted from mentor payout              |
| **Mentor past-deadline reschedule accepted**   | 25% of session fee deducted from mentor payout              |
| **Mentor no-show penalty (strike 3+)**         | 25% of session fee deducted per no-show                     |
| **Refund - before first session**              | Full cash refund                                            |
| **Refund - after first session completed**     | Credit only, no cash                                        |
| **Within-deadline mentor reschedule rejected** | Customer gets credit only, no cash refund                   |
| **No mentor response to request**              | Auto-approved after response window expires                 |
| **No customer response to proposal**           | Original booking reinstated                                 |

Immigroov Consulting VOF · Confidential · June 2026