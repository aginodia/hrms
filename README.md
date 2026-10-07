# Altius Investech HRMS

A single-file HRMS (`index.html`) for Altius Investech, with Supabase as the database, auth and file storage. You host it on Netlify.

**Built so far**

| Module | What it covers |
| --- | --- |
| 1. Sign in / Access control | Sign-up (Name, Email, Phone, Password) → admin gives access or rejects → employee uploads KYC → admin approves (or sends it back) → HRMS access |
| 2. Employee Master Data (EMD) | Team list (Name, Mail ID, Number, Designation, Reporting Manager, Salary, Last Increment) → detailed info per employee with locked personal fields, editable EID / designation / manager, a month-wise salary history, and the KYC documents |
| 3. Payroll | Upload the month's punch-in/punch-out sheet → map sheet EmpCodes to employees → day-wise F / HD / L marking from HR's working-hours rules → admin adjustments → monthly payable per employee, minus Professional Tax, saved as the month's payroll |
| 4. Finance | Variable pay, Bonus & Leave Encashment, Monthly Expenses (from the Google Form), ESOPs (placeholder) |

**Two separate access levels**

* **Admin** (`sayan.mullick@altiusinvestech.com` is the base admin): Dashboard, Access Control, Employee Master Data, Finance (Payroll, Variable, Bonus & Leave Encash, Monthly Expense, ESOPs), and Team Access settings.
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

In **Authentication → Providers → Email**, keep **Confirm email** turned **on** (recommended). Sign-up confirmation and password-reset links use the Site URL above.

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
Sign up ──► [pending] ──Admin: Give access──► [kyc_pending] ──Employee submits KYC──► [kyc_submitted]
   │                                               ▲                                     │
   │                                               └────────Admin: Send back (note)──────┤
   └──── Admin: Reject (at any of these stages) ──► [Rejected] ──Admin: Restore──► back to [pending]
                                                                                          │
                                         Admin: Approve (DOJ, EID, designation, manager, starting salary)
                                                                                          ▼
                                                                    [active] → appears in Employee Master Data
```

**KYC form (employee).** Files must be PDF or JPG, up to 5 MB each.
Required: Aadhaar, PAN, 10th marksheet, 12th marksheet, graduation marksheet, date of birth, bank account number + IFSC, and an emergency contact (name, relationship, number).
Optional: last payslip and leave (relieving) letter.
Files upload as soon as they're picked, and the form keeps a local draft, so a page refresh doesn't lose any work.

**Approval (admin).** In Access Control → KYC Review, open the submission, view each document, then either:
* **Approve**: sets the date of joining and, optionally, EID, designation, reporting manager and starting salary.
* **Send back**: returns the KYC to the employee with a note on what to fix.
* **Reject KYC**: cancels their access. A reason is required, and the employee sees it when they sign in.

**Rejecting.** A sign-up, someone awaiting KYC, or a submitted KYC can be rejected. Nothing is deleted: the person moves to **Access Control → Rejected**, with the stage and reason, and can't use the HRMS. **Restore** sends them back to Signup Requests.

**Salary history (EMD → Show detailed info).** Each row is *Month · Year · Salary*, meaning "from this month onwards the salary is X". For example:

| Effective from | Salary |
| --- | --- |
| May 2026 | ₹20,000 |
| Dec 2026 | ₹25,000 ← current |

The entry with the latest month is the current salary. That entry's month and % change are shown as **Last Increment** in the EMD list. Click **Save** to store all edits (EID, designation, reporting manager, salary rows) in one go. A removed salary row is hidden but kept in the database as an audit trail.

**Signing out.** **Sign out** is in the top bar on every page (and at the bottom of the sidebar). It ends the session on this device, even if the network call to Supabase fails. If a session expires, the app returns to the sign-in screen with a message.

## Payroll (Module 3)

**Admin → Payroll** has three tabs.

**1. Upload attendance.** Click **Upload attendance** and pick the month's `.xlsx` (`.xls` and `.csv` also work). Two layouts are understood:
* **The biometric system's export** (e.g. `SalarySheetSept26.xlsx`, sheet "Raw Sheet"): one block per employee, with an `Empcode 0003 … Name …` row, then `Date | Day | Shift | IN | Out1 | In2 | … | In8 | Out`, then one row per date. **IN** is the first punch of the day and the last **Out** column is the final punch; `--:--` means no punch. The "Total Present / Total Working HRS" rows and the other sheets in the workbook are ignored.
* **A simple table** with the columns **EmpCode · Name · Date · Day · IN · OUT**, one row per employee per day. Header names are matched loosely (for example `Emp Code`, `In Time`, `Punch Out`), and title rows above the header are skipped. The file is read in the browser: only the rows are saved to Supabase (`attendance_punches`), never the Excel file. Uploading the same month again replaces it, keeps the old upload as history, and carries your day-wise changes over.

**2. Mapping.** Each EmpCode in the sheet is mapped to an employee in Employee Master Data. **The EmpCode must be the same as the Employee ID in EMD**: case and leading zeros are ignored (`0003` = `003`), but prefixes are not (`0047` ≠ `AI-0047`). Names are never used. Matching IDs are suggested, and you confirm with **Save mapping**. A mapping where the IDs differ (or the employee has no Employee ID) is flagged in red here and in the salary table, and saving it asks for confirmation. Only mapped employees appear in the salary calculation. Mappings are remembered for later months.

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

**Save payroll** stores each employee's counts and payable for the month (`payroll_results`). **Export CSV** downloads the same table. If anything changes after saving, the status shows "Changed since save".

## Finance sections

**Variable.** Use **Manage eligibility** to tick the eligible employees. Each eligible employee has a **Detailed info** page where you add calculations:
Variable = (Buy × Buy commission % + Sell × Sell commission %) − (Current salary × Duration in months × Sales time allocated %).
The current salary comes from EMD (the latest salary entry). The result is calculated in the database, shown with its working, and kept in a payout history that you can edit or remove. A negative result is shown in red as "nothing payable".

**Bonus & Leave Encash.** Use **Manage eligibility**, then **Add line** for each payment: Employee | Description | Month | Amount. Tick **Current salary** to use the employee's current salary as the amount; the amount is fixed when you save. Totals are shown per month. Removed lines are kept for audit.

**Monthly Expense.** The team submits expenses through a Google Form. In the form, go to **Responses → Link to Sheets**, then share that responses sheet as **Anyone with the link: Viewer**. Paste the sheet's link on the Monthly Expense page and click **Sync**. The columns (Employee ID, Amount, Timestamp, Name, Expense date, Category, Description, Bill) are detected automatically and can be changed. Each response is matched to an employee by **Employee ID**, using the same rule as Payroll mapping. Responses that don't match are listed and flagged. **Detailed info** shows an employee's claims month by month, with bill links. Syncing again adds new responses and never duplicates old ones.

**ESOPs.** Placeholder. Share how grants, vesting and exercise should work and it will be built to match.

### Choices I made where the brief left a gap
* **Date of birth** is collected in the KYC form. **Date of joining** is set by the admin at approval. Both are locked afterwards, along with name, email and phone.
* **Reject** keeps the record (under Rejected) instead of deleting it, so HR has a history and can restore a request made by mistake.
* **Reporting manager** is picked from active employees.
* The base admin also appears in EMD, so their own salary and designation can be recorded.
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
* `variable_entries`: variable-pay calculations (inputs, salary used, result)
* `bonus_payments`: bonus and leave-encashment lines
* `expense_claims`: expenses synced from the Google Form responses sheet, matched to employees by Employee ID
