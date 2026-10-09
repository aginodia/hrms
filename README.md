# Altius Investech HRMS

A single-file HRMS (`index.html`) for Altius Investech, with Supabase as the database, auth and file storage. You host it on Netlify.

**Built so far**

| Module | What it covers |
| --- | --- |
| 1. Sign in / Access control | Sign-up (Name, Email, Phone, Password) → admin gives access (straight into the HRMS) or rejects; or the admin adds the employee directly. KYC is asked at sign-in, can be skipped and done later, and is verified by admin without blocking access |
| 2. Employee Master Data (EMD) | Team list (Name, Mail ID, Number, Designation, Reporting Manager, Salary, Last Increment) → detailed info per employee with locked personal fields, editable EID / designation / manager, a month-wise salary history, and the KYC documents |
| 3. Payroll | Upload the month's punch-in/punch-out sheet → map sheet EmpCodes to employees → day-wise F / HD / L marking from HR's working-hours rules → admin adjustments → monthly payable per employee, minus Professional Tax, saved as the month's payroll |
| 4. Finance | Variable (uploaded sheet), Bonus & Leave Encashment, Loans (repaid from Variable / Bonus), Monthly Expenses (from the Google Form), ESOPs (placeholder) |
| 5. Exits & logs | Resignation → notice period → Resigned / Terminated (R&T) → F&F 60 days after the last working day; Active and R&T tabs in payroll; an activity log for each section, by employee and by month |

**Two separate access levels**

* **Admin** (`sayan.mullick@altiusinvestech.com` is the base admin): Dashboard, Access Control, Employee Master Data, Finance (Payroll, Variable, Bonus & Leave Encash, Loans, Monthly Expense, ESOPs), and Team Access settings.
* **Team**: a separate employee portal (Home, My Profile). A team member only ever sees their own records.

The database enforces this split, not just the screens. Row Level Security and `SECURITY DEFINER` functions in the migration under `supabase/migrations/` do the enforcing. Team accounts have no write access to any table. They can't change their own role or status, and they can't read anyone else's rows or files. Admin decides what employees can see about themselves (job details, salary history, KYC documents) on the **Team Access** page.

---

## Live project status

The Supabase project **Altius HRMS** (`bejhmbvwaexpafhkseod`) is set up through the Supabase connector:

* Tables, row-level security, the `kyc-documents` storage bucket and its policies, and the sign-up trigger are applied.
* The base admin account `sayan.mullick@altiusinvestech.com` exists, with its email confirmed and role admin / active.
* All migrations in `supabase/migrations/` are applied, including Payroll. Nothing is left to run by hand.

The steps below are for setting up a fresh project from scratch.

## Setup (about 10 minutes)

### 1. Create the database schema
The project is `bejhmbvwaexpafhkseod`, and `index.html` already points at it. Apply the migrations in [`supabase/migrations/`](supabase/migrations), in filename order, **one** of these two ways:

**A. Supabase CLI** (from the repo root on your machine):
```bash
supabase login
supabase init            # only adds supabase/config.toml; the migrations folder already exists
supabase link --project-ref bejhmbvwaexpafhkseod   # asks for the database password
supabase db push
```

**B. Dashboard:** open **SQL Editor → New query**, paste each migration file in turn (oldest first) and click **Run**.

Either way you get the tables, security policies, functions and the private `kyc-documents` storage bucket. The files are safe to run again. Future modules will be added as new files in `supabase/migrations/`.

### 2. Configure auth
In **Authentication → URL Configuration**:
* **Site URL**: your Netlify URL, e.g. `https://altius-hrms.netlify.app`
* **Redirect URLs**: add the same URL (plus `http://localhost:8080` if you test locally)

In **Authentication → Providers → Email**, turn **Confirm email** **off**. The HRMS sends no emails; admin approval is the gate (see *Sign-in without emails* below).

### 3. Create the base admin account
Do this **right after** running the schema.

* **Option A (recommended):** go to **Authentication → Users → Add user → Create new user**. Enter `sayan.mullick@altiusinvestech.com` and a password, and tick **Auto Confirm User**.
* **Option B:** open the deployed site, click **Create an account** with that email, then click the confirmation link.

Either way, that email automatically becomes an **active admin**. Every other sign-up starts as a pending request.

> Why "right after": the admin role is tied to that email address. With email confirmation on, only someone with access to that inbox can claim it.

### 4. Keys in `index.html` (already done)
`index.html` already contains the project URL and the **publishable** key:

```js
const SUPABASE_URL = 'https://bejhmbvwaexpafhkseod.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_…';
```

The publishable key is meant to be public. Row Level Security protects the data. **Never** put the secret / `service_role` key or the database password in this file or in the repo.

### 5. Deploy to Netlify
* **Quickest:** drag `index.html` onto <https://app.netlify.com/drop>.
* **From GitHub:** in Netlify, **Add new site → Import from Git**, pick this repo, leave the build command empty, and set the publish directory to `/`.

Then update the Site URL in step 2 if your Netlify URL changed.

---

## How the flow works

```
Sign up ──► [pending] ──Admin: Give access (DOJ, EID, …)──► [active] → in Employee Master Data, can use the HRMS
   │                                                            │
   └── Admin: Reject ──► [Rejected] ──Restore──► [pending]      │   KYC runs alongside, never blocks:
                                                                │   not submitted ──employee submits──► to review
Admin: Add employee (creates the login) ────────────────────────┘        ▲                               │
                                                                         └──── Admin: Send back (note) ◄──┤
                                                                                 Admin: Approve ──► verified
```

There is **no bottleneck**. Once access is given (or the admin adds the employee), the person is in Employee Master Data and in payroll at once.

**Add employee (admin).** Click **Add employee** in Employee Master Data or Access Control. Enter:
* Name, email and phone.
* A temporary password (auto-generated; click ↻ for a new one).
* Date of joining.
* Optionally: Employee ID, designation, reporting manager and starting salary.

The login is created and the employee is added to EMD straight away. A sign-in summary (link, email, temporary password) is shown to copy and share. The employee can change the password in **My Profile → Change password**. If email confirmation is switched on in Supabase, they must click the confirmation email first.

**Upload Excel (admin).** Use this to add many employees at once. The **Upload Excel** button is in Employee Master Data and Access Control.
1. **Download template** gives an `.xlsx` with one row per employee and the same fields as Add employee: Full Name*, Email*, Phone, Date of Joining* (DD-MM-YYYY), Employee ID, Designation, Reporting Manager (Emp ID or email), Salary From (MM-YYYY), Monthly Salary, Temporary Password. A "How to fill" sheet explains each column. Your own sheet works too if its headers match.
2. **Upload filled sheet** shows a preview: each row is marked *Ready*, *Already in the HRMS* (skipped), or with its problem (bad email, missing joining date, duplicate email, Employee ID already used, and so on).
3. Click **Add**. For each Ready row, a login is created and the person goes straight into Employee Master Data. Managers listed in the same sheet are added first, so their team members can report to them.
4. **Sign-in details (CSV)** gives each person's email and temporary password, to share.

Rows with problems are left out. Fix them in the sheet and upload it again; people already added are skipped. Because email confirmation is on in Supabase, each new login sends a confirmation email. If Supabase's email limit is reached, the upload stops and the remaining rows show *Not added yet*. Upload the same file again later to add them.

**Clearing test data.** `supabase/scripts/clear_test_data.sql` removes every user except the admin login (which keeps its Employee ID) and all KYC, salary, payroll, finance and log data. It keeps the settings. Run it once in the Supabase SQL Editor. It is not a migration, and it cannot be undone.

**Give access (admin).** In Access Control → Signup Requests, **Give access** opens the same employment form: date of joining (defaults to today), Employee ID, designation, manager and starting salary. The person moves into EMD immediately.

**KYC (employee).** When they sign in, the KYC form is shown with **Skip for now**. Skipping takes them into the HRMS. Home then shows a *Complete your KYC* card, and **My KYC** in the menu carries a badge. The form shows again at their next sign-in until it is submitted. Files must be PDF or JPG, up to 5 MB each.
Required: Aadhaar, PAN, 10th marksheet, 12th marksheet, graduation marksheet, date of birth, bank account number + IFSC, and an emergency contact (name, relationship, number).
Optional: last payslip and leave (relieving) letter.
Files upload as soon as they're picked, and the form keeps a local draft, so a page refresh doesn't lose any work.

**KYC review (admin).** Access Control has two KYC tabs:
* **KYC Review** lists submitted KYCs. Open one, view the documents, then **Approve KYC** or **Send back** with a note. The employee sees the note and resubmits.
* **KYC not submitted** lists employees who skipped the form or were sent back.

EMD rows carry a *KYC not submitted / sent back / to review* tag until the KYC is verified.

**Assign Emp ID (EMD).** An employee without an Employee ID shows **+ Assign Emp ID** in the list; anyone else shows a ✎ next to their ID to change it.
* Only the ID is needed, nothing else.
* IDs are unique ignoring case and leading zeros (0007 = 007), the same rule Payroll uses.
* The change is recorded in the employee's Activity log.
* Payroll → Mapping suggests the match for that EmpCode straight away.

**Rejecting.** A sign-up request can be rejected. Nothing is deleted: the person moves to **Access Control → Rejected**, with the reason, and can't use the HRMS. **Restore** sends them back to Signup Requests.

**Salary history (EMD → Show detailed info).** Each row is *Month · Year · Salary*, meaning "from this month onwards the salary is X". For example:

| Effective from | Salary |
| --- | --- |
| May 2026 | ₹20,000 |
| Dec 2026 | ₹25,000 ← current |

The entry with the latest month is the current salary. That entry's month and % change are shown as **Last Increment** in the EMD list. Click **Save** to store all edits (EID, designation, reporting manager, salary rows) in one go. A removed salary row is hidden but kept in the database as an audit trail.

**Employment status (EMD → Show detailed info → Status).**
1. **Resignation**: enter the date the employee resigned, then pick a notice period (30 / 45 / 60 / 90 days) or **Manual** to choose the last working day (LWD) from the calendar. The employee shows **On notice period** with the LWD, and stays in Active and in payroll. Use **Edit notice** or **Withdraw** if plans change.
2. **Resigned** (or **Terminated**, available at any time): confirm the last working day. The employee moves to **Resigned & Terminated** in both EMD and Payroll.
3. **F&F** is settled **60 days after the last working day**. The *Settle by* date and the days left are shown in EMD and Payroll. Clicking **Complete F&F** ends the employee's journey: they drop out of every sheet, can no longer sign in, and stay read-only under **F&F completed**. F&F can't be undone.

The EMD list has three tabs: **Active** (including those on notice), **Resigned & Terminated**, and **F&F completed**. **Mark active again** clears an exit before F&F.

**Sign-in without emails.** The HRMS sends no emails at all. There are no sign-in codes, no confirmation links and no reset emails. Admin approval is the gate.
* **Sign-in** needs only the email and password.
* **Sign-up**: the person fills in the form and sees "Your request is with the admin" straight away. They can't use the HRMS until an admin clicks **Give access** in Access Control. Giving access also confirms the account's email in Supabase.
* **Forgot password**: the sign-in page tells the person to ask the HR admin.
  * The admin opens **Access Control → Reset password**, picks the person and sets a temporary password. One is suggested.
  * The admin copies the sign-in details and shares them.
  * The base admin's password can only be changed by the base admin.
* **Change password** when signed in (team: My Profile; admin: Settings → My Account): enter the current password, then the new one twice.

**One Supabase setting is needed.** It's a dashboard setting, so the app can't change it: Authentication → Sign In / Providers → **Email** → turn **Confirm email** **off** and save. While it is on, every sign-up tries to send a confirmation email.

Custom SMTP and the email templates are no longer used, so they can stay off.

**Switching emails back on later.** Set `const SEND_AUTH_EMAILS = true;` near the top of `index.html`. This brings back the emailed codes for sign-in, forgot password and change password. It needs working SMTP and the templates to show `{{ .Token }}`:
* *Magic link or OTP* for sign-in.
* *Reset password* for forgot password.
* *Reauthentication* for change password.

If those emails hang for about 10 seconds and the Auth logs show `504 request_timeout`, check the SMTP settings:
* **Port:** `587` or `465`, not 25.
* **Host:** for example `smtp.gmail.com` or `smtp.office365.com`.
* **Username:** the full mailbox address.
* **Password:** an App Password.
* **Sender:** the same mailbox.

**Admins: Super Admin and Base Admin.** Admins use only the admin console (no employee portal). There are two levels:

| | Super Admin (full, e.g. co-founders) | Base Admin (partial, e.g. HR) |
| --- | --- | --- |
| Admin console (Access Control, EMD, payroll, finance, settings) | ✓ | ✓ |
| Give, change or remove admin access | ✓ | ✗ |
| Change a Super Admin's record, reset an admin's password | ✓ | ✗ |
| In Employee Master Data and payroll | ✗ (Non-EMD) | ✓ |
| Employee ID and reporting manager | Not needed, only a designation | Yes, like any employee |

* **Access Control → Admins** lists both levels. A Super Admin can **Give admin access** (pick the person and the level, plus a designation for a Super Admin), switch someone between **Make Super** / **Make Base**, **Remove** admin access, and edit a Super Admin's designation. A Base Admin sees the list but gets no buttons.
* **Add employee** (Super Admins only) has a **Type**: *Employee* or *Super Admin — management (Non-EMD)*. Choosing Super Admin hides Employee ID, reporting manager and salary.
* **Non-EMD now means Super Admin.** The old Non-EMD option for other people is gone. Anyone who was marked Non-EMD moved back into Employee Master Data.
* **The owner.** The first admin (`BASE_ADMIN_EMAIL`) is always a Super Admin. Nobody can change it, and nobody can change their own admin access.
* **All existing admins became Super Admins** when this was applied. Use **Make Base** for HR.
* **Enforced in the database, not just hidden in the screen.** A trigger on `profiles` stops a Base Admin from changing admin access or a Super Admin's record, whichever function they call.

**Org Structure** (admin menu → People). A reporting tree:
* Super Admins are at the top, each with their designation. Everyone else sits under their reporting manager.
* People without a manager are listed under **Not placed yet**. Set a reporting manager in EMD; a Super Admin can be picked as the manager.
* Click anyone in the tree to open them in EMD.
* People who have resigned or been terminated, and anyone whose F&F is done, are left out.

**Holidays & time relaxation** (admin menu → Attendance → Holidays). Dates are added by hand for each financial year (1 April – 31 March).
* **Holidays:** Date and Description. A holiday from Monday to Saturday is paid as a full day (`H`). A Sunday holiday stays a weekly off.
* **Time relaxation:** Date, Description, Hours and Minutes.
  * On that day, working the time you set counts as a full day. Example: Diwali at 5h instead of 8h30, so 5 hours worked is a full day.
  * The time must be shorter than the usual full day.
* **Rules:** one entry per date, and removing an entry keeps it in the activity log.
* **Employees** see the calendar read-only under **Holidays** in the portal.

**WFH** (admin menu → Attendance → WFH).
* **Employees** add WFH dates in the portal under **WFH**, either a single date or a range. Sundays and holidays are skipped.
  * Past dates are allowed only within the **current month**: a WFH day from a week ago can be added later, but not one from an earlier month.
  * Once a month is pushed it is locked for employees.
* **Admins** can pick **WFH** in the Final line of day-wise attendance, next to F / HD / L. That records the WFH in the WFH list, marked as added by an admin.
  * Picking another value on a WFH day rejects the WFH and saves that value instead.
* **How payroll counts it:** an employee's own WFH replaces a day with no punches. A WFH added or confirmed by an admin always counts. Both are paid as a full day.
* **The WFH page** lists every entry and how it was counted. Admins can **Reject** / **Restore** an entry or **Add WFH** for someone.

**Leaves register** (admin menu → Attendance → Leaves).
* Record leaves day by day: type the **Employee ID or name**, pick a date or a range, choose **Full day** or **Half day**, and add a note if needed.
* Sundays and holidays are skipped. Adding a leave on a date that already has one changes it to the new type.
* **Synced to payroll:** a full-day leave makes the day **L** and a half-day leave makes it **HD**. The day can still be changed in day-wise attendance.
* **Day-wise page:** its Leaves card shows which no-punch days are in the register.
* **The page** lists the month's leaves with a remove button, and a folded **By employee** summary of total leave days.

**Day-wise attendance:** **Save changes** takes you back to the Payroll page, ready for the next person. The four summary cards (Half days, Missed punches, Leaves, Admin changes) start folded; click one to open it.

**Save & push, and salary queries.**
* **Save & push** (Payroll → Salary Calculation) saves the payroll and publishes each employee's final day-wise sheet in their **My Pay**, matched by Employee ID.
  * Employees can't edit the sheet.
  * The portal shows only pushed months.
  * Pushing again updates the sheets.
* **Queries:** for **12 hours from the first push**, an employee can click **Ask** on a **Leave** or **Half day** and say what it should be, with a reason. Full days can't be questioned, and there is one open query per date. After 12 hours the Ask buttons close.
* **Admins aren't time-limited.**
  * Open queries show as a badge on Payroll and an alert on the Salary Calculation page, and the person's row is highlighted.
  * On the day-wise page the queried dates are outlined. The admin changes the day in the Final line and saves, marks the query **Resolved**, or **Rejects** it with a note.
  * Then **Save & push** again so the employee sees the change.

**Rules & formulas** (admin menu → Settings). The salary formula, day statuses, holiday / relaxation, leave, WFH, push and query rules, mapping, exits, admin levels and portal rules are all on this one page. Other pages no longer repeat them; they show a small **Rules** link that opens the matching section.

**Layout and behaviour**
* **Sidebar:** the menu scrolls on its own, and keeps its position and the current page in view as you move between pages.
* **Sign out** asks first, with **Stay** / **Sign out** buttons.
* **Payroll table:**
  * One line per person, with the EmpCode shown once.
  * The Pre-adjustment columns are tinted blue and the Post-adjustment columns green. The pre and post cards on the day-wise page have the same colours.
  * The mapping flag (ID mismatch) is shown only in the Mapping tab.
* **Summary popup:** includes each person's final net pay and the section totals, with tighter rows.
* **WFH page:** split into **By employee** and **By admin**. The WFH menu item shows a badge with the number of WFH days employees added since you last opened the page.
* **Salary queries resolve automatically** when the queried day has been changed and you save on the day-wise page, click Save payroll, or Save & push.
  * When a month's attendance is re-uploaded, its open queries move to the new upload and are checked the same way.
* **Resigned & Terminated:** these employees can't raise salary queries or add WFH.
* **Employee portal:** a section that changed since the person last opened it shows **New** in their menu, and "Updated since your last visit" at the top of the page. This covers My Pay, WFH, Holidays, My Profile and My KYC.

**KYC: Save vs Skip.** The KYC form has **Save & finish later**, which stores whatever has been filled in, even if it's only the emergency contact. It isn't submitted, and the form reopens with those details. **Skip** stores nothing from that visit: anything typed and any files uploaded during it are discarded. Admins see each employee's KYC status on their EMD page, with **Review — approve or send back** once it's submitted, as well as in Access Control → KYC Review.

**Change requests.** Once KYC is submitted, employees can't edit their details directly. In **My Profile → Request a change** they ask for a new name, phone, date of birth, bank account / IFSC or emergency contact. **Nothing changes until an admin approves it** in Access Control → **Change requests**. That tab shows each detail's current and requested value, with **Approve** or **Reject** (a reason is required to reject). The employee sees the outcome, and can withdraw a request while it's still waiting. Only one request can be waiting at a time.

**Employee portal.**
* **Home:** Employee ID, designation, manager, joining date, current salary, last net pay, loan remaining, and the KYC status.
* **My Profile:** personal, employment, bank and emergency details, documents, salary history, change requests, and change password.
* **My Pay:** monthly payroll (days, earned, PT, net pay), bonus and leave encashment, variable, and loans with the remaining balance.

What employees see follows **Team Access**: job details, salary history and KYC documents as before, plus new switches for *Monthly pay* and *Bonus, variable & loans*.

**Signing out.** **Sign out** is in the top bar on every page (and at the bottom of the sidebar). It ends the session on this device, even if the network call to Supabase fails. If a session expires, the app returns to the sign-in screen with a message.

## Payroll (Module 3)

**Admin → Payroll** has three tabs.

**1. Upload attendance.** Click **Upload attendance** and pick the month's `.xlsx` (`.xls` and `.csv` also work). Two layouts are understood:
* **The biometric system's export** (e.g. `SalarySheetSept26.xlsx`, sheet "Raw Sheet"): one block per employee, with an `Empcode 0003 … Name …` row, then `Date | Day | Shift | IN | Out1 | In2 | … | In8 | Out`, then one row per date. **IN** is the first punch of the day and the last **Out** column is the final punch; `--:--` means no punch. The "Total Present / Total Working HRS" rows and the other sheets in the workbook are ignored.
* **A simple table** with the columns **EmpCode · Name · Date · Day · IN · OUT**, one row per employee per day. Header names are matched loosely (for example `Emp Code`, `In Time`, `Punch Out`), and title rows above the header are skipped. The file is read in the browser: only the rows are saved to Supabase (`attendance_punches`), never the Excel file. Uploading the same month again replaces it, keeps the old upload as history, and carries your day-wise changes over.

**2. Mapping.** Each EmpCode in the sheet is mapped to an employee in Employee Master Data. **The EmpCode must be the same as the Employee ID in EMD**: case and leading zeros are ignored (`0003` = `003`), but prefixes are not (`0047` ≠ `AI-0047`). Names are never used. Matching IDs are suggested, and you confirm with **Save mapping**. A mapping where the IDs differ (or the employee has no Employee ID) is flagged in red here and in the salary table, and saving it asks for confirmation. Only mapped employees appear in the salary calculation. Mappings are remembered for later months.

**People who have left.** The first sheets will include people who left before the HRMS existed. In the Mapping dropdown, choose **Left / resigned — not in HRMS**, or use **Mark not-mapped as left** to do every unmapped row at once, then click **Save mapping**. Left EmpCodes are kept out of payroll and are not counted as "not mapped". From then on they are folded into a closed **Left / resigned — N hidden** list, so they no longer appear for mapping in later months. To undo one, open that list and change its dropdown back.


**4. Professional Tax.** HR keeps the PT slabs (monthly salary from → to → PT amount). Each employee's monthly salary is matched to a slab, and that PT is deducted: **Net payable = Earned − PT**. The slabs are prefilled with West Bengal rates (up to ₹10,000: ₹0; ₹10,001–15,000: ₹110; ₹15,001–25,000: ₹130; ₹25,001–40,000: ₹150; above ₹40,000: ₹200). Check these against the current notification.

**3. Working Hours.** HR sets how long a full day is for **Monday–Friday** and for **Saturday**, and whether Sunday is a paid weekly off. Defaults are 9h 00m, 5h 00m and paid.

**How each day is marked (system calculation / pre-adjustment)**

| Mark | Rule |
| --- | --- |
| **F** Full day | Both IN and OUT, and the time between them meets the full-day hours for that weekday |
| **HD** Half day | Both IN and OUT, but less than the full-day hours |
| **MP** Missed punch | Only IN or only OUT. Counted as a full day, except **every 3rd missed punch** in the month, which becomes a half day |
| **L** Leave | No IN and no OUT on a working day (also a working day missing from the sheet) |
| **WO** Weekly off | Sunday |
| — | Days before the employee's date of joining (not counted). If the sheet has punches before the joining date in EMD (staff added to the HRMS after they joined), the joining date is ignored for that month and a warning is shown. "—" days can also be changed in the Final line |

**Salary Calculation tab.** Lists mapped employees with the pre-adjustment (system) and post-adjustment (final) counts of Full / Half / Leave, plus the payable amount. Click an employee to see their **day-wise attendance**: one column per date, with rows for Day, IN, OUT, worked time, the **System** mark, and the **Final** mark. In the Final row, HD, L and missed-punch days have a dropdown so the admin can change them. Below the grid are reports listing the short-hours half days, the missed punches (and which one became a half day), the leaves, and the admin's changes.

**Salary formula** (from the Final line):
daily salary = monthly salary (the salary in effect for that month, from EMD; if the first salary entry starts later, that entry is used and flagged) ÷ 30
payable = Full days × daily + Half days × daily × 0.5, rounded to the nearest rupee. Paid Sundays count as full days.

**Active and R&T tabs.** The salary table has two tabs. **Active** lists working employees; those on notice get an *On notice · LWD* tag. **Resigned & Terminated** lists every R&T employee until F&F, even in months where they are not in the attendance sheet. Each row shows:
* the last working day, highlighted;
* the *Settle by* date;
* the month's Final F / HD / L and net payable;
* **Check** (opens the day-wise table, or the EMD record if they aren't in the sheet) and **F&F**, side by side.

**Last working day in the calculation.** Days after the last working day are not counted (striped in the day-wise table). The LWD column is highlighted in red, and the table scrolls to it when it opens. If the sheet has punches after the LWD, a warning is shown.

**Summary button.** Click **Summary** to open a count table for the month: **Name | FD | HD | HD-PM | Leave**, both pre-adjustment (system) and post-adjustment (final). HD is a half day for short hours; HD-PM is a half day from missed punches (every 3rd miss). Click a name to open that employee's day-wise table.

**Save payroll** stores each employee's counts and payable for the month (`payroll_results`). **Export CSV** downloads the same table. If anything changes after saving, the status shows "Changed since save".

## Finance sections

**Variable.** No calculation is done in the HRMS. Calculate the variable outside the HRMS and upload the sheet:
1. Click **Template** to download a CSV (`Emp ID, Name, Variable Amount, Remarks`) prefilled with your employees. Your own sheet also works, as long as it has an **Emp ID** column and a **Variable Amount** (or **Amount**) column; title rows above the header are skipped.
2. Click **Upload sheet**, pick the payout month, review the preview (matched / not matched), then click **Import**. Rows are matched to employees **by Emp ID**, using the same rule as Payroll mapping. Rows that don't match are kept and flagged "Emp ID not in EMD". Uploading the same month again replaces the earlier rows (tick or untick **Replace**) and reverses any loan deductions on them.
3. The table shows **Emp ID | Name | Variable | Loan remaining | Loan deduct (₹) | Deduct full | Net payout | Remarks | Details**.

**Bonus & Leave Encash.** Use **Manage eligibility**, then fill a line in **Add payments** for each payment: Employee | Description | Date | Amount | Loan deduct (₹) | Net. Tick **Current salary** to use the employee's current salary. If the employee has a loan, enter a deduction or tick **Deduct full**; otherwise the cell shows *No loan*. Click **Save payments**: the lines leave the add section and go into the **Payments log**. Saved payments can't be edited or deleted, so the log stays complete. The log has one line per payment:

| Date | Employee | E-Code | Desc. | Amount | Loan deduction | Net amount |
| --- | --- | --- | --- | --- | --- | --- |
| 26/10/2026 | Sayan | 0003 | Bonus | 20,000 | 18,000 | 2,000 |

It can be filtered by month. Clicking an employee's name shows only their payments.

**Bulk populate** fills the add section for many people at once. Enter a **Description** (what the payment is for); the **Date** defaults to today (dd-mm-yyyy). Then choose who gets a line:
* **Give all**: every eligible employee.
* **Select from the list**: everyone starts ticked; untick the people who shouldn't get it.

Each line is filled in automatically, with the employee's **current salary** as the amount. For anyone with a loan, the **Loan deduct** cell is left **blank** and highlighted, to be filled in by hand (or tick *Deduct full*). Review the lines, adjust any of them, then click **Save payments** as usual. The single **Add line** flow works exactly as before.

**Loans.** **Add a loan** form: pick the **Name**, and the **Emp ID** is filled in from EMD; then enter the **Amount taken** and the **Date**, and click **Add**. The list shows **Emp ID | Name | Amount | DD-MM-YYYY | Loan remaining | Details**. A loan is repaid through the **Loan deduct** column on Variable and Bonus lines:
* Type an amount to deduct part of the line, or tick **Deduct full** to deduct the whole line (capped at what is still owed).
* Example: a variable of ₹50,000 with *Deduct full*, against a ₹2,00,000 loan, leaves **₹1,50,000** remaining, and the variable's net payout is ₹0.
* If an employee has several loans, the oldest is repaid first.
* Changing or removing the line, or re-uploading the variable month, reverses the deduction automatically.
* **Add repayment** on a loan's **Details** page records money paid back directly: **Date** (shown as dd-mm-yyyy) and **Amount**, plus an optional note. It can't be more than what is still owed. The loan remaining goes down, and the repayment is logged.
* **Details** lists the loan and every repayment or deduction, oldest first, with the remaining amount after each. A loan can be removed only while it has no repayments (for loans added by mistake).

**Logs.** Every change is logged with who made it and when: uploads, line changes, loan deductions, loans, status changes, F&F and payroll saves.
* Each section's employee **Details** page shows that employee's log for the section.
* EMD → Show detailed info shows the employee's **Activity log** across all sections.
* The Variable, Bonus and Loans pages each have a **Month log** with a month picker.

**Monthly Expense.** The team submits expenses through a Google Form. In the form, go to **Responses → Link to Sheets**, then share that responses sheet as **Anyone with the link: Viewer**. Paste the sheet's link on the Monthly Expense page and click **Sync**. The columns (Employee ID, Amount, Timestamp, Name, Expense date, Category, Description, Bill) are detected automatically and can be changed. Each response is matched to an employee by **Employee ID**, using the same rule as Payroll mapping. Responses that don't match are listed and flagged. **Detailed info** shows an employee's claims month by month, with bill links. Syncing again adds new responses and never duplicates old ones.

**ESOPs.** The allocation comes from the ESOP Excel (the `Esop_Historical.xlsx` layout; **Template** downloads a blank copy):
* The title row holds `ALLOCATION DATE 2nd APRIL 2026`, and a cell holds `Exercise Period : 4 years`.
* The header row starts with **Member Name**. The grant columns (Performance, Time-weighted, Historical) come before **Allocation Schedule**, and the schedule columns (`Mar'27`, `Mar'28` …) say how many options vest on the last day of that month. The member list ends at the **Total** row.
* **Upload allocation Excel** shows a preview. Names are matched to employees (exact name, or a unique first/last-name match), and the rest can be linked in the preview or later on the page. Re-uploading the same allocation date replaces it.
* The page shows tiles for **Total pool / Granted / Vested / Unvested / Exercised / Returned to pool**, a pool bar, grants by type, a vesting-timeline chart, and an employee-wise table. Clicking a row shows the tranche statuses, grants, exercises (**Record exercise**, capped at what has vested), linking and the stages.
* **Edit pool** changes the pool (2,000 by default).
* On resignation or termination, unvested options after the notice date go back to the pool. Vested options lapse back to the pool if not exercised within 6 months of the last working day (30 days for a termination) or by the end of the exercise period.
* Employees see **My ESOPs** in the portal: their tiles, a timeline chart, stages, grants, exercises and a summary of the scheme. The summary is written into the app; the scheme document itself is not stored. Team Access → **ESOPs** hides it.

### Choices I made where the brief left a gap
* **Date of birth** is collected in the KYC form. **Date of joining** is set by the admin at approval. Both are locked afterwards, along with name, email and phone.
* **Reject** keeps the record (under Rejected) instead of deleting it, so HR has a history and can restore a request made by mistake.
* **Reporting manager** is picked from active employees.
* The base admin also appears in EMD, so their own salary and designation can be recorded.
* **Exits:** an R&T employee stays in payroll and variable until F&F, because their last month's salary and dues are still paid. On notice counts as Active. Variable rows for an F&F'd employee's Emp ID are not matched.
* **Variable eligibility** is no longer used: the uploaded sheet decides who gets variable. Bonus still uses eligibility.
* **Payroll:** Sunday is a weekly off and, by default, paid, so a full month of attendance gives the full salary with the ÷30 rule. A 31-day month can therefore pay slightly more than the monthly salary; HR can turn paid Sundays off. A day missing from the sheet counts as leave. The same time punched twice counts as one punch, and 00:00 counts as no punch.

---

## Project files

| File | Purpose |
| --- | --- |
| `index.html` | The whole app: HTML, CSS and JS. Loads `supabase-js` and the Inter font from CDNs. |
| `supabase/migrations/20261006000000_hrms_modules_1_2.sql` | Tables, RLS policies, storage bucket and policies, sign-up trigger, and the access/KYC functions. Re-runnable. |
| `supabase/migrations/20261006130000_reject_and_salary_audit.sql` | Reject / restore, saving employee details, and the salary audit trail. Re-runnable. |
| `supabase/migrations/20261007000000_payroll_attendance.sql` | Payroll: attendance uploads and punches, EmpCode mapping, day-wise adjustments, saved payroll, working-hours rules. Admin-only. Re-runnable. |
| `supabase/migrations/20261007120000_finance_pt_variable_bonus_expenses.sql` | Professional Tax slabs and PT in saved payroll, eligibility, variable entries, bonus/leave-encashment lines, synced expense claims, `norm_emp_code()`. Admin-only. Re-runnable. |
| `supabase/migrations/20261018000000_esop.sql` | ESOPs: allocations, grants, vesting tranches and exercises (`esop_*` tables), pool setting, `admin_import_esop`, `admin_map_esop_member`, `admin_add_esop_exercise`, `my_esops()`. |
| `supabase/migrations/20261017000000_query_autoresolve_left_updates.sql` | Queries resolve automatically on push when their day changed (and carry over after a re-upload), no queries / WFH after leaving, `my_updates()` for the portal's New markers. |
| `supabase/migrations/20261016000000_leaves_register_wfh_month.sql` | Leaves register (`leave_records`, `admin_add_leaves`, `admin_remove_leave`); employee WFH back-dating limited to the current month. |
| `supabase/migrations/20261015000000_calendar_wfh_payroll_push.sql` | Holiday & time-relaxation calendar (`calendar_days`), WFH (`wfh_days`), Save & push (`payroll_runs.pushed_at`, `payroll_results.days`, `admin_push_payroll`), salary queries with the 12-hour window (`payroll_queries`), `my_payslips()`; the portal's pay list shows pushed months only. |
| `supabase/migrations/20261014000000_admin_levels_org.sql` | Super Admin / Base Admin (`admin_level`, `is_super_admin`, `admin_set_admin_level`, `admin_set_designation`), the guard trigger on `profiles`, Non-EMD only for Super Admins. |
| `supabase/migrations/20261013000000_no_auth_emails.sql` | Sign-in without emails: giving access confirms the account, admins set temporary passwords (`admin_set_password`), and accounts already approved or waiting are confirmed once. |
| `supabase/migrations/20261012000000_roles_nonemd_kyc_drafts_change_requests.sql` | Admin give/revoke, Non-EMD (member type), KYC drafts (Save vs Skip), change requests with admin approval, and `my_portal()` for the employee portal. Re-runnable. |
| `supabase/migrations/20261011000000_payroll_left_codes.sql` | Payroll mapping: mark sheet EmpCodes as left / resigned (kept out of payroll and hidden in later months). Re-runnable. |
| `supabase/migrations/20261010000000_onboarding_no_bottleneck.sql` | Give access straight into EMD, KYC status alongside (skip / submit / send back / approve without blocking), Assign Emp ID with logging; moves anyone mid-onboarding into the HRMS. Re-runnable. |
| `supabase/migrations/20261009000000_notice_bonus_ledger_repayments.sql` | Notice period (resignation date + last working day), the add-only bonus ledger with payment dates, and manual loan repayments. Admin-only. Re-runnable. |
| `supabase/migrations/20261008000000_exits_variable_upload_loans.sql` | Employment status and F&F, the finance activity log, variable sheet uploads, loans and loan deductions from Variable / Bonus. Admin-only. Re-runnable. |

### Data model
* `profiles`: one row per user (name, email, phone, role, status, EID, designation, reporting manager, DOJ, DOB, rejection details, audit timestamps)
* `kyc_submissions`: document paths, bank details and emergency contact (one row per employee)
* `salary_history`: `(employee_id, effective_month, amount)`, one row per revision; removed rows keep `removed_at` / `removed_by`
* `app_settings`: `team_visibility` toggles, controlled by admin
* Storage bucket `kyc-documents` (private): `<user_id>/<document>-<timestamp>.pdf|jpg`. Files open through 10-minute signed links.
* `payroll_runs`: one attendance upload per month (older uploads kept as history)
* `attendance_punches`: EmpCode, name, date, day, IN, OUT for each row of the uploaded sheet
* `attendance_code_map`: sheet EmpCode → employee
* `attendance_adjustments`: the admin's day-wise F / HD / L changes
* `payroll_results`: saved monthly counts and payable per employee
* `comp_eligibility`: who is eligible for Variable / Bonus
* `variable_entries`: the earlier calculated variable entries (kept, no longer used by the UI)
* `variable_uploads` / `variable_payouts`: uploaded variable sheets and their rows (Emp ID, name, amount, remarks, matched employee, loan deduction)
* `loans` / `loan_deductions` / `loan_repayments`: loans taken, deductions from Variable / Bonus lines (voided, not deleted, when reversed), and manual repayments
* `finance_log`: who did what, per section, employee and month
* `bonus_payments`: bonus and leave-encashment payments (date, amount, loan deduction); read-only once saved
* `esop_allocations` / `esop_grants` / `esop_vesting` / `esop_exercises`: ESOP allocation uploads, grants per member and type, vesting tranches, and exercises
* `expense_claims`: expenses synced from the Google Form responses sheet, matched to employees by Employee ID
