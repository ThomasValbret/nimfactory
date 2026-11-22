CREATE TABLE IF NOT EXISTS loans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  borrower TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,
  lent_on TEXT NOT NULL,
  due_on TEXT,
  returned_on TEXT,
  note TEXT NOT NULL DEFAULT ''
);
