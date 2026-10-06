# Altius Investech HRMS

A single-file HRMS (`index.html`) for Altius Investech, with Supabase as the database, auth and file storage. You host it on Netlify.

**Built so far**

| Module | What it covers |
| --- | --- |
| 1. Sign in / Access control | Sign-up (Name, Email, Phone, Password) → admin gives access or rejects → employee uploads KYC → admin approves (or sends it back) → HRMS access |
| 2. Employee Master Data (EMD) | Team list (Name, Mail ID, Number, Designation, Reporting Manager, Salary, Last Increment) → detailed info per employee with locked personal fields, editable EID / designation / manager, a month-wise salary history, and the KYC documents |

**Two separate access levels**

* **Admin** (`sayan.mullick@altiusinvestech.com` is the base admin): Dashboard, Access Control, Employee Master Data, and Team Access settings.
* **Team**: a separate employee portal (Home, My Profile). A team member only ever sees their own records.

The database enforces this split, not just the screens. Row Level Security and `SECURITY DEFINER` functions in the migration under `supabase/migrations/` do the enforcing. Team accounts have no write access to any table. They can't change their own role or status, and they can't read anyone else's rows or files. Admin decides what employees can see about themselves (job details, salary history, KYC documents) on the **Team Access** page.

---

## Setup (about 10 minutes)

### 1. Create the database schema
The project is `bejhmbvwaexpafhkseod`, and `index.html` already points at it. Apply the migration in [`supabase/migrations/`](supabase/migrations) **one** of these two ways:

**A. Supabase CLI** (from the repo root on your machine):
```bash
supabase login
supabase init            # only adds supabase/config.toml; the migrations folder already exists
supabase link --project-ref bejhmbvwaexpafhkseod   # asks for the database password
supabase db push
```

**B. Dashboard:** open **SQL Editor → New query**, paste the whole migration file and click **Run**.

Either way you get the tables, security policies, functions and the private `kyc-documents` storage bucket. The file is safe to run again. Future modules will be added as new files in `supabase/migrations/`.

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
   └──Admin: Reject → sign-up deleted              └────────Admin: Send back (note)──────┤
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

**Salary history (EMD → Show detailed info).** Each row is *Month · Year · Salary*, meaning "from this month onwards the salary is X". For example:

| Effective from | Salary |
| --- | --- |
| May 2026 | ₹20,000 |
| Dec 2026 | ₹25,000 ← current |

The entry with the latest month is the current salary. That entry's month and % change are shown as **Last Increment** in the EMD list. Click **Save** to store all edits in one go.

### Choices I made where the brief left a gap
* **Date of birth** is collected in the KYC form. **Date of joining** is set by the admin at approval. Both are locked afterwards, along with name, email and phone.
* **Reject** deletes the sign-up entirely, so that person can sign up again later if needed.
* **Reporting manager** is picked from active employees.
* The base admin also appears in EMD, so their own salary and designation can be recorded.

---

## Project files

| File | Purpose |
| --- | --- |
| `index.html` | The whole app: HTML, CSS and JS. Loads `supabase-js` and the Inter font from CDNs. |
| `supabase/migrations/20261006000000_hrms_modules_1_2.sql` | Tables, RLS policies, storage bucket and policies, and RPC functions. Re-runnable. |

### Data model
* `profiles`: one row per user (name, email, phone, role, status, EID, designation, reporting manager, DOJ, DOB, audit timestamps)
* `kyc_submissions`: document paths, bank details and emergency contact (one row per employee)
* `salary_history`: `(employee_id, effective_month, amount)`, one row per revision
* `app_settings`: `team_visibility` toggles, controlled by admin
* Storage bucket `kyc-documents` (private): `<user_id>/<document>-<timestamp>.pdf|jpg`. Files open through 10-minute signed links.
