// Repeated jobs on the board page: the list, a play button per row, and an
// editor that will not save a crontab the engine would refuse.
//
// TKT-839 built the read-only list. TKT-843 adds the two things he asked for:
// msg 6484, "each repeated job record has a play button. That the user can run
// them anytime bypass the schedule", and msg 6485, "for the schedule add a
// tooltips on crontab style scheduler. Also, if the format is wrong, will be
// highlighted red and not letting the user save it until it is corrected".
//
// THE VALIDATION IS NOT HERE. It is a POST to /jobs/check, which asks
// Tira::Job::schedule_refusal and gives back the ENGINE's own message. Writing
// a crontab regex in this file would be the second validator for one format,
// which is how the engine and the browser came to disagree about attachment
// content types (TKT-713). This file renders the answer; it does not decide it.
//
// Pure ASCII on purpose - t/16 asserts it, because a non-ASCII glyph in a live
// script reaches the browser double-encoded.

const jobsSection = document.querySelector(".board--jobs");
if (jobsSection) {
  const jobsCards = jobsSection.querySelector(".jobs-cards");
  const jobsError = jobsSection.querySelector(".jobs-error");
  const jobsFail = (message) => {
    jobsError.textContent = message;
    jobsError.hidden = false;
  };
  const jobsOk = () => {
    jobsError.hidden = true;
  };

  const post = (path, payload) =>
    fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    }).then((response) =>
      response.json().then((body) => {
        if (!response.ok) {
          throw new Error(body && body.error ? body.error : "That did not work.");
        }
        return body;
      })
    );

  // What the crontab fields mean, in the order cron reads them. A tooltip
  // rather than a link, because somebody typing a schedule wants the answer
  // where their hands already are.
  const CRON_HELP = [
    "Five fields, in this order:",
    "  minute        0-59",
    "  hour          0-23",
    "  day of month  1-31",
    "  month         1-12",
    "  day of week   0-7 (0 and 7 are both Sunday)",
    "",
    "* is every value, a-b is a range, a,b is a list,",
    "and /n takes every nth - so */5 * * * * is every",
    "five minutes and 0 3 * * 1 is 03:00 each Monday.",
    "",
    "Or the single word 'monitor' for a poller that",
    "stays running instead of firing on a tick."
  ].join("\n");

  let editing = null;

  const closeEditor = () => {
    const open = jobsSection.querySelector(".jobs-editor");
    if (open) {
      open.remove();
    }
    editing = null;
  };

  // One modal for both jobs. Called with a job it edits that job; called with
  // nothing it creates one, which is TKT-858 - until then a job could be run,
  // edited and listed here and created only from a terminal.
  //
  // The two differ in exactly two places: a create needs a command as well as a
  // schedule, and it posts no id, which is what tells the provider to add
  // rather than update. Everything else - the tooltip, the debounced check
  // against the engine, the save that stays blocked until the answer comes
  // back - is the same code, because a second editor would be a second place
  // for the crontab rules to drift.
  const openEditor = (job) => {
    closeEditor();
    const creating = !job || !job.id;
    editing = creating ? null : job.id;

    const panel = document.createElement("div");
    panel.className = "jobs-editor";

    const heading = document.createElement("h3");
    heading.className = "jobs-editor__heading";
    heading.textContent = creating ? "Add a repeated job" : "Edit " + job.id;
    panel.appendChild(heading);

    const label = document.createElement("label");
    label.className = "jobs-editor__label";
    label.textContent = "Schedule";
    label.title = CRON_HELP;
    panel.appendChild(label);

    const field = document.createElement("input");
    field.className = "jobs-editor__schedule";
    field.type = "text";
    field.value = (job && job.schedule) || "";
    field.title = CRON_HELP;
    label.appendChild(field);

    // Only when creating. An edit posts the schedule alone, exactly as it did
    // before this card, so nothing about the existing path changes.
    let commandField = null;
    if (creating) {
      const commandLabel = document.createElement("label");
      commandLabel.className = "jobs-editor__label";
      commandLabel.textContent = "Command";
      panel.appendChild(commandLabel);

      commandField = document.createElement("input");
      commandField.className = "jobs-editor__command";
      commandField.type = "text";
      commandField.value = "";
      commandLabel.appendChild(commandField);
    }

    const why = document.createElement("p");
    why.className = "jobs-editor__why";
    why.hidden = true;
    panel.appendChild(why);

    const save = document.createElement("button");
    save.className = "jobs-editor__save";
    save.type = "button";
    save.textContent = "Save";
    panel.appendChild(save);

    const cancel = document.createElement("button");
    cancel.className = "jobs-editor__cancel";
    cancel.type = "button";
    cancel.textContent = "Cancel";
    cancel.addEventListener("click", closeEditor);
    panel.appendChild(cancel);

    // Asked of the engine, debounced so a keystroke is not a request. While
    // the answer is outstanding the save stays blocked: refusing to save
    // something not yet judged is the safe direction, and it is the direction
    // his "not letting the user save it until it is corrected" asks for.
    let pending = null;
    const judge = () => {
      const schedule = field.value;
      save.disabled = true;
      if (pending) {
        window.clearTimeout(pending);
      }
      pending = window.setTimeout(() => {
        post("/jobs/check", { schedule: schedule })
          .then((answer) => {
            if (field.value !== schedule) {
              return;
            }
            const bad = answer && answer.ok === false;
            field.classList.toggle("is-invalid", Boolean(bad));
            why.textContent = bad ? answer.refusal : "";
            why.hidden = !bad;
            // A create with no command is refused by the engine anyway, so
            // blocking it here saves a round trip rather than deciding
            // anything - the rule still lives in _job_fields.
            save.disabled =
              Boolean(bad) || (creating && !commandField.value.trim());
          })
          .catch(() => {
            // A check that could not be made is not a schedule that is fine.
            field.classList.add("is-invalid");
            why.textContent = "The schedule could not be checked, so it cannot be saved.";
            why.hidden = false;
            save.disabled = true;
          });
      }, 250);
    };

    field.addEventListener("input", judge);

    // The command gates the save too when creating, so typing one has to
    // re-ask. Without this the save stays disabled after a perfectly good
    // command is typed, until the schedule field happens to be touched - the
    // button would look broken for the one field this card added.
    if (creating) {
      commandField.addEventListener("input", judge);
    }

    judge();

    save.addEventListener("click", () => {
      save.disabled = true;
      // No id is what tells the provider to add rather than update, so a
      // create must not send one - not even an empty string, which the
      // provider treats the same way but which would read here as though an
      // id were meant.
      const payload = creating
        ? { schedule: field.value, command: commandField.value }
        : { id: job.id, schedule: field.value };
      post("/jobs/save", payload)
        .then(() => {
          jobsOk();
          closeEditor();
          loadJobs();
        })
        .catch((error) => {
          // The engine refused on write what the check let through - a stale
          // page, most likely. Its message is shown rather than a generic one.
          field.classList.add("is-invalid");
          why.textContent = error.message;
          why.hidden = false;
        });
    });

    jobsSection.appendChild(panel);
    field.focus();
  };

  const jobRow = (job) => {
    const li = document.createElement("li");
    li.className = "jobs-card";
    li.dataset.enabled = job.enabled ? "1" : "0";

    const idEl = document.createElement("div");
    idEl.className = "jobs-card__id";
    idEl.textContent = job.id + " - " + (job.enabled ? "enabled" : "disabled");
    li.appendChild(idEl);

    const schedEl = document.createElement("div");
    schedEl.className = "jobs-card__schedule";
    schedEl.textContent = job.schedule;
    li.appendChild(schedEl);

    const whatEl = document.createElement("div");
    whatEl.className = "jobs-card__what";
    whatEl.textContent = job.mode === "command" ? job.command : job.message;
    li.appendChild(whatEl);

    // TKT-859. This line used to join the mode and schedule-kind fields with a
    // dash, so every row said "command - monitor" or "command - cron" at the
    // reader. Those are storage values, not English, and his key detail on that
    // card predicted that a fix which only adjusted spacing would leave them.
    //
    // The old expression is described rather than quoted here on purpose:
    // t/499 greps this file for it, and a comment reproducing it verbatim
    // fails that guard. Better a strict guard and a wordier comment than a
    // test taught to ignore comments, which is where the string would hide.
    //
    // REWRITTEN RATHER THAN DELETED, decided as CHK-002 before implementing:
    // the line carries real information - whether the job runs a command or
    // announces a message, and whether it fires on a tick or stays up - and
    // dropping it would trade an ugly row for a less informative one.
    //
    // Three combinations, not four: a monitor whose only content is a message
    // is refused at write time by _job_fields (TKT-842), because a monitor with
    // no command can never be found alive in the process table.
    const modeEl = document.createElement("div");
    modeEl.className = "jobs-card__mode";
    // The monitor-with-no-command branch is for data that should not exist:
    // _job_fields refuses it at write time, so a record in that shape came from
    // somewhere else - an older release, an import, a hand-edited file. Raised
    // in review, and the point is what it must NOT do. Checking the kind alone
    // would call such a job "Stays running", which is the one thing it cannot
    // do: a monitor with no command has nothing to run. It says so instead,
    // which surfaces the bad record rather than dressing it as a healthy one.
    modeEl.textContent =
      job.schedule_kind === "monitor"
        ? job.mode === "message"
          ? "Monitor with no command - it cannot run"
          : "Stays running"
        : job.mode === "message"
          ? "Announces a message when due"
          : "Runs a command when due";
    li.appendChild(modeEl);

    // The play button. On a cron row it runs the job now, whatever the
    // schedule says; on a MONITOR row it starts it, because a monitor has no
    // schedule to bypass - it is either up or it is not, and starting it is
    // what answers the monitor-dead finding printed beside it. TKT-843 CHK-001.
    const play = document.createElement("button");
    play.className = "jobs-card__play";
    play.type = "button";
    play.textContent = job.schedule_kind === "monitor" ? "Start" : "Run now";
    play.title =
      job.schedule_kind === "monitor"
        ? "Start this monitor now"
        : "Run this job now, without waiting for its schedule";
    play.addEventListener("click", () => {
      play.disabled = true;
      post("/jobs/run", { id: job.id })
        .then((result) => {
          jobsOk();
          const status = result && typeof result.status === "number" ? result.status : null;
          const output = result && result.output ? String(result.output).trim() : "";
          // A job that ran and failed must SAY so. Silence after a failure is
          // indistinguishable from never having run, which is the ambiguity
          // this whole feature exists to remove - and a button that swallows
          // it rebuilds that in one click.
          if (status !== null && status !== 0) {
            jobsFail(job.id + " exited " + status + (output ? ": " + output : ""));
          } else if (result && result.pid) {
            jobsFail(job.id + " started as pid " + result.pid);
          } else if (output) {
            jobsFail(job.id + ": " + output);
          } else {
            jobsFail(job.id + " ran, with no output.");
          }
          loadJobs();
        })
        .catch((error) => jobsFail(job.id + ": " + error.message))
        .then(() => {
          play.disabled = false;
        });
    });
    li.appendChild(play);

    const edit = document.createElement("button");
    edit.className = "jobs-card__edit";
    edit.type = "button";
    edit.textContent = "Edit";
    edit.addEventListener("click", () => openEditor(job));
    li.appendChild(edit);

    return li;
  };

  const loadJobs = () =>
    fetch("/jobs", { cache: "no-store" })
      .then((response) => {
        if (!response.ok) {
          throw new Error("jobs failed");
        }
        return response.json();
      })
      .then((jobs) => {
        jobsCards.replaceChildren(...jobs.map(jobRow));
      })
      .catch(() => jobsFail("Could not read the repeated jobs."));

  // The control TKT-858 is about. Everything else on this section could
  // already be done from the page; creating a job could only be done from a
  // terminal.
  //
  // It opens the SAME editor the pencil opens, with no job, which is what makes
  // the payload carry no id and the provider add rather than update.
  const add = document.createElement("button");
  add.className = "jobs-add";
  add.type = "button";
  add.textContent = "Add a job";
  add.addEventListener("click", () => openEditor(null));
  jobsSection.insertBefore(add, jobsCards);

  loadJobs();
  // Not while somebody is typing in the editor: a refresh that replaced the
  // rows under an open panel would throw away what they had written.
  //
  // `editing` is null while the ADD panel is open, because there is no job
  // being edited yet - so the refresh below would pull the rows out from under
  // a half-typed new job. The panel's own presence is what has to be checked.
  window.setInterval(() => {
    if (!editing && !jobsSection.querySelector(".jobs-editor")) {
      loadJobs();
    }
  }, 30000);
}
