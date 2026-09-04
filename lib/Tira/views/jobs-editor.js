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
  // THE LOG OUTLIVES THE RENDER, and it has to. This section reloads itself
  // every thirty seconds, which rebuilds every card - so a log box owned by the
  // card element would be wiped twice a minute, leaving less behind than the
  // status line it replaces. Keyed by job id, held here, and re-rendered onto
  // whatever card element exists at the time. TKT-882.
  const runLogs = new Map();
  const LOG_LINES = 100;

  const rememberLines = (id, text) => {
    const kept = runLogs.get(id) || [];
    const now = Date.now();
    for (const line of String(text).replace(/\s+$/, "").split("\n")) {
      kept.push({ at: now, line: line });
    }
    // A fixed ring, the same shape and reasoning as the request log this
    // dashboard already keeps: 100 lines bounds memory without assuming an
    // output rate, so a job watched overnight holds kilobytes.
    while (kept.length > LOG_LINES) {
      kept.shift();
    }
    runLogs.set(id, kept);
  };

  // Under a minute old is fresh - his "yellow" - and it is computed from the
  // moment the line arrived rather than tracked by a timer per line, so a tab
  // left in the background catches up correctly when it comes forward.
  const FRESH_MS = 60000;
  const paintLog = (box, id) => {
    const kept = runLogs.get(id) || [];
    box.textContent = "";
    if (!kept.length) {
      box.hidden = true;
      return;
    }
    const now = Date.now();
    for (const entry of kept) {
      const span = document.createElement("span");
      span.className =
        "jobs-card__log-line" + (now - entry.at < FRESH_MS ? " is-fresh" : "");
      span.textContent = entry.line + "\n";
      box.appendChild(span);
    }
    box.hidden = false;
    // Auto-scrolling, which is what makes it a tail rather than a transcript
    // somebody has to drag to the bottom of.
    box.scrollTop = box.scrollHeight;
  };

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

    // A CONTROL, NOT A TYPED WORD. His voice 6691: choose Monitor or Schedule
    // with radio buttons rather than typing "monitor" into a schedule field.
    // The engine has always stored the kind as the schedule string itself, so
    // "monitor" was a magic value a person had to know; a radio makes the same
    // record without the folklore. TKT-890, absorbed by TKT-892.
    const kindRow = document.createElement("div");
    kindRow.className = "jobs-editor__kind";
    panel.appendChild(kindRow);

    const kindName = "jobs-editor-kind-" + (creating ? "new" : job.id);
    const makeRadio = (row, group, value, text, checked) => {
      const wrap = document.createElement("label");
      wrap.className = "jobs-editor__radio";
      const input = document.createElement("input");
      input.type = "radio";
      input.name = group;
      input.value = value;
      input.checked = checked;
      wrap.appendChild(input);
      wrap.appendChild(document.createTextNode(" " + text));
      row.appendChild(wrap);
      return input;
    };

    const startsMonitor = !job || (job.schedule || "") === "monitor";
    const kindMonitor = makeRadio(kindRow, kindName, "monitor", "Monitor", startsMonitor);
    makeRadio(kindRow, kindName, "schedule", "Schedule", !startsMonitor);

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

    // ALWAYS, NOT ONLY WHEN CREATING. His complaint 2 of 2026-09-03 - "I cannot
    // edit and card" - was not that the edit forgot the command: it was that the
    // command input was built inside if (creating), so there was nowhere on the
    // page to type a correction into. The save provider has always accepted a
    // changed command; nothing ever sent one. His voice 6695 asks for one
    // complete form serving create AND edit, pre-filled from the job. TKT-892.
    let commandField = null;
    {
      const commandLabel = document.createElement("label");
      commandLabel.className = "jobs-editor__label";
      commandLabel.textContent = "Command";
      panel.appendChild(commandLabel);

      commandField = document.createElement("input");
      commandField.className = "jobs-editor__command";
      commandField.type = "text";
      // Pre-filled from the job on edit, empty on create - "the same form,
      // filled with the card's own data", his 6695. A form that opened blank
      // over an existing job would invite retyping a command that is already
      // right, and a typo there is a monitor that stops doing its work.
      // FILLED FROM THE JOB'S OWN MODE, not always from command.
      //
      // There is one text input serving both modes, and it used to be filled
      // from job.command whatever the job was. A message job has no command, so
      // the box opened EMPTY - and the save below reads this same field into
      // payload.message, so saving from that screen wrote the empty box over the
      // stored message. JOB-001, JOB-002 and JOB-003 are all message-mode and
      // their message is the hunt instruction the agent acts on. TKT-914.
      commandField.value =
        (job && (job.mode === "message" ? job.message : job.command)) || "";
      commandLabel.appendChild(commandField);
    }

    // Command or Message, also a control rather than an inference. And MESSAGE
    // IS NOT OFFERED UNDER MONITOR, because the engine refuses that pairing
    // outright: a monitor with no command can never be found alive in the
    // process table, so it would be reported dead for ever (TKT-842). Hiding
    // the option is not the page deciding - it is the page declining to offer
    // what the save would refuse, which is the same reason the schedule field
    // is put out of reach under Monitor.
    const modeRow = document.createElement("div");
    modeRow.className = "jobs-editor__mode";
    panel.appendChild(modeRow);

    const modeName = "jobs-editor-mode-" + (creating ? "new" : job.id);
    // DERIVED FROM THE JOB, the way startsMonitor above derives the kind. These
    // two were hardcoded true and false, so every job opened showing Command
    // whatever it was - the form never asked what mode it had. That is the same
    // omission as the field value above and they have to be fixed together:
    // Message selected over an empty box looks correct, where Command over an
    // empty box at least looks wrong. TKT-914.
    const startsMessage = Boolean(job) && (job.mode || "") === "message";
    const modeCommand = makeRadio(modeRow, modeName, "command", "Command", !startsMessage);
    const modeMessage = makeRadio(modeRow, modeName, "message", "Message", startsMessage);
    const messageWrap = modeMessage.parentNode;

    // His voice 6694, and a CHECKBOX rather than a radio because that is what he
    // said and what it means: looping is on or off, not one of two alternatives.
    // Off by default - a default here would restart things nobody asked to have
    // restarted. It comes from something he actually did: JOB-006 was a while
    // loop typed into a command field to keep police running, and it never ran
    // once.
    const loopRow = document.createElement("div");
    loopRow.className = "jobs-editor__loop";
    panel.appendChild(loopRow);

    const loopLabel = document.createElement("label");
    loopLabel.className = "jobs-editor__radio";
    const loopBox = document.createElement("input");
    loopBox.type = "checkbox";
    loopBox.className = "jobs-editor__loop-on";
    loopBox.checked = Boolean(job && job.restart_every);
    loopLabel.appendChild(loopBox);
    loopLabel.appendChild(document.createTextNode(" Restart when it ends, every"));
    loopRow.appendChild(loopLabel);

    const loopEvery = document.createElement("input");
    loopEvery.type = "number";
    loopEvery.className = "jobs-editor__loop-every";
    loopEvery.min = "2";
    // Five is his number. The floor of 2 is measured rather than chosen: below
    // about two seconds the feeder's quiet window never elapses, so a healthy
    // monitor reports no output at all and reads as dead.
    loopEvery.value = (job && job.restart_every) || 5;
    loopRow.appendChild(loopEvery);
    loopRow.appendChild(document.createTextNode(" seconds"));

    // How often a monitor says it will speak - his Q-115 answer, and EMPTY
    // MEANS NO EXPECTATION rather than zero, which is why this is left blank
    // rather than defaulted.
    const expectRow = document.createElement("label");
    expectRow.className = "jobs-editor__label";
    expectRow.textContent = "Expect a line every (minutes, blank for no expectation)";
    panel.appendChild(expectRow);

    const expectField = document.createElement("input");
    expectField.type = "number";
    expectField.className = "jobs-editor__expect";
    expectField.min = "1";
    expectField.value = (job && job.expect_every) || "";
    expectRow.appendChild(expectField);

    // What each choice puts out of reach. Under Monitor there is no schedule to
    // write and no message to send; in Message mode there is no command to
    // loop. Disabled rather than hidden so the form does not change shape as
    // somebody clicks through it.
    const applyKind = () => {
      const monitoring = kindMonitor.checked;
      field.disabled = monitoring;
      messageWrap.hidden = monitoring;
      if (monitoring && modeMessage.checked) {
        modeCommand.checked = true;
      }
      // AND THE MODE ROW GOES AWAY UNDER MONITOR. His report, 2026-09-04: "you
      // don't need to show the Command radio button since there is only 1
      // option to select". Message is already refused for a monitor by the
      // engine - a monitor with no command could never be found alive in the
      // process table - so the group offers one real choice and reads as a
      // question nobody has answered. TKT-912.
      //
      // HIDDEN, NOT REMOVED, and the line above is why: the save path reads
      // modeMessage.checked, and applyKind itself sets modeCommand.checked
      // when a message job is switched to Monitor. A form that deleted the
      // controls would build its payload from an undefined one.
      modeRow.hidden = monitoring;
      expectRow.hidden = !monitoring;
      const looping = modeCommand.checked && !modeMessage.checked;
      loopRow.hidden = !looping;
      loopEvery.disabled = !loopBox.checked;
    };

    kindRow.addEventListener("change", () => {
      applyKind();
      judge();
    });
    modeRow.addEventListener("change", () => {
      applyKind();
      judge();
    });
    loopBox.addEventListener("change", applyKind);

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
      const schedule = kindMonitor.checked ? "monitor" : field.value;
      save.disabled = true;
      if (pending) {
        window.clearTimeout(pending);
      }
      pending = window.setTimeout(() => {
        post("/jobs/check", { schedule: schedule })
          .then((answer) => {
            // HAS THE INPUT CHANGED SINCE THIS REQUEST WENT OUT? That is the
            // only question this guard means to ask, and it must be asked
            // about the value that was SENT - so it is recomputed exactly the
            // way `schedule` was built above.
            //
            // It used to compare the schedule box against `schedule`
            // directly, which is the same thing for a cron job and never true
            // for a monitor: there
            // `schedule` is the literal "monitor" while field.value is the
            // schedule box, empty or holding whatever cron text was typed
            // before. So the callback returned on this line every time and
            // the line that re-enables Save, below, never ran - the button
            // was dead from the first keystroke for every monitor. TKT-912.
            const current = kindMonitor.checked ? "monitor" : field.value;
            if (current !== schedule) {
              return;
            }
            const bad = answer && answer.ok === false;
            field.classList.toggle("is-invalid", Boolean(bad));
            why.textContent = bad ? answer.refusal : "";
            why.hidden = !bad;
            // A create with no command is refused by the engine anyway, so
            // blocking it here saves a round trip rather than deciding
            // anything - the rule still lives in _job_fields.
            // The command gates the save on BOTH paths now that both have the
            // field. Emptying an existing job's command is refused by the engine
            // exactly as creating without one is, so blocking it here saves a
            // round trip rather than deciding anything - the rule still lives in
            // _job_fields.
            save.disabled = Boolean(bad) || !commandField.value.trim();
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
    commandField.addEventListener("input", judge);

    // Once at open, so the form arrives in the right shape rather than in the
    // shape it would have had if somebody had already clicked something.
    applyKind();
    judge();

    save.addEventListener("click", () => {
      save.disabled = true;
      // No id is what tells the provider to add rather than update, so a
      // create must not send one - not even an empty string, which the
      // provider treats the same way but which would read here as though an
      // id were meant.
      // ONE SHAPE, NOT TWO. The only difference between creating and editing is
      // whether an id is present - that is what tells the provider to add rather
      // than update - and a create must not send one, not even an empty string,
      // which the provider treats the same way but which would read here as
      // though an id were meant.
      const payload = {
        schedule: kindMonitor.checked ? "monitor" : field.value,
      };
      // A SAVE THAT WOULD BLANK A STORED MESSAGE IS REFUSED, not sent.
      //
      // This is the half that costs something. The three hunt jobs carry their
      // instruction in `message`, and an emptied one fires on schedule and says
      // nothing - which reads as the agent ignoring a hunt rather than as a lost
      // field. Refusing rather than warning, because there is no undo here and
      // the value is not recoverable from the form once it has gone. TKT-914.
      if (
        job &&
        (job.message || "").trim() !== "" &&
        modeMessage.checked &&
        !kindMonitor.checked &&
        commandField.value.trim() === ""
      ) {
        jobsFail(
          "That would erase this job's message, and there is no undo. " +
            "Type the message, or switch to Command if this job should run one."
        );
        return;
      }
      if (modeMessage.checked && !kindMonitor.checked) {
        payload.message = commandField.value;
      } else {
        payload.command = commandField.value;
      }
      // Sent only when the control that owns it is in play. An interval sent
      // for a message job, or an expectation sent for a cron job, is refused by
      // the engine - correctly - so the form does not offer it and does not
      // send it either.
      // NULL RATHER THAN NOTHING when the control is in play but empty. An
      // absent key means "leave it alone" to the engine, so omitting these
      // would make the checkbox one-way: it could add a restart interval and
      // never take one away, and the form would report success over a job it
      // had not changed. Sending null clears it, which is what unticking means.
      if (!loopRow.hidden) {
        payload.restart_every = loopBox.checked ? Number(loopEvery.value) : null;
      }
      if (!expectRow.hidden) {
        payload.expect_every =
          expectField.value === "" ? null : Number(expectField.value);
      }
      if (!creating) {
        payload.id = job.id;
      }
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

    // TKT-880's question, answered last on purpose - "decide the panel shape
    // once its contents are settled", and they are now: a heading, two radio
    // pairs, a schedule, a command, a looping row and an expectation. That is
    // too much to inline into a card row the way a tasklist card edits itself,
    // so it stays a panel.
    //
    // WHAT DOES CHANGE IS WHERE IT OPENS. It was appended to the end of the
    // section, so editing the first of a dozen jobs put the form far below the
    // card it belonged to, with the two never on screen together. It now opens
    // directly beneath that card. Creating still appends, because there is no
    // card for a job that does not exist yet.
    const owner = creating
      ? null
      : jobsSection.querySelector('[data-job="' + job.id + '"]');
    if (owner && owner.parentNode) {
      owner.parentNode.insertBefore( panel, owner.nextSibling );
    } else {
      jobsSection.appendChild(panel);
    }
    field.focus();
  };

  // How long ago, in words, because a timestamp is a thing to decode and this
  // line is read at a glance. Whole units only - "3 minutes ago" rather than
  // "3.4" - since the extra precision would be invented: last_output_at is
  // stamped when the feeder flushes a batch, not when the line was produced.
  // TKT-863.
  //
  // THIS IS DISPLAY ONLY AND ROUNDS BOTH WAYS. 89 minutes reads "1 hour ago"
  // and 91 reads "2 hours ago". Whoever adds the red state once Q-115 is
  // answered must compare against last_output_at itself, never against this
  // string or the number behind it - a threshold read off a rounded label is
  // wrong by up to half a unit in the direction nobody chose.
  const sinceWords = (ms) => {
    const s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + (s === 1 ? " second ago" : " seconds ago");
    const m = Math.round(s / 60);
    if (m < 60) return m + (m === 1 ? " minute ago" : " minutes ago");
    const h = Math.round(m / 60);
    if (h < 24) return h + (h === 1 ? " hour ago" : " hours ago");
    const d = Math.round(h / 24);
    return d + (d === 1 ? " day ago" : " days ago");
  };

  const jobRow = (job) => {
    const li = document.createElement("li");
    li.className = "jobs-card";
    li.dataset.enabled = job.enabled ? "1" : "0";
    // So the editor can open BESIDE the card it is editing rather than at the
    // bottom of the section. TKT-880.
    li.dataset.job = job.id;

    const idEl = document.createElement("div");
    idEl.className = "jobs-card__id";
    idEl.textContent = job.id + " - " + (job.enabled ? "enabled" : "disabled");
    li.appendChild(idEl);

    const schedEl = document.createElement("div");
    schedEl.className = "jobs-card__schedule";
    // THE WORDS, decided by the engine (Tira::Job::job_schedule_words) and
    // carried on the row. The raw cron stays reachable as the tooltip, because
    // the words are an addition rather than a replacement - it is still STORED
    // as cron, and somebody checking the exact minutes needs to see them.
    // Falls back to the raw string if an older server has not sent the words,
    // rather than rendering nothing. TKT-884.
    schedEl.textContent = job.schedule_words || job.schedule;
    schedEl.title = job.schedule;
    li.appendChild(schedEl);

    const whatEl = document.createElement("div");
    whatEl.className = "jobs-card__what";
    whatEl.textContent = job.mode === "command" ? job.command : job.message;
    li.appendChild(whatEl);

    // TKT-859. This line used to join the mode and schedule-kind fields with a
    // dash, so every row showed the two stored values instead of English. They
    // are storage vocabulary, and his key detail on that card predicted that a
    // fix which only adjusted spacing would leave them.
    //
    // NEITHER THE OLD EXPRESSION NOR ITS OUTPUT IS QUOTED HERE, and the second
    // half of that took a walk through the card's own test steps to notice:
    // this whole file is embedded verbatim in the served page, so a comment
    // carrying the old strings shipped them to every browser that loaded the
    // board. The rows were clean and the page was not. t/499 now checks the
    // assembled page as well as this file.
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

    // TKT-861. Whether the process is actually up, for a monitor that is
    // supposed to be. Until this, a monitor that died an hour ago looked
    // exactly like one polling happily.
    //
    // The verdict is NOT computed here - the payload carries it, from the same
    // job_monitor_alive that monitor-dead uses, so the page and the police
    // bridge cannot answer one question two ways in front of him.
    //
    // The field is ABSENT for a cron job and for a disabled monitor, both of
    // which are not supposed to be up. Testing for presence rather than truth
    // keeps that distinction: a row with nothing to say says nothing, instead
    // of saying "not running" at every cron job on the board.
    if (Object.prototype.hasOwnProperty.call(job, "running")) {
      const upEl = document.createElement("div");
      upEl.className = "jobs-card__up";
      upEl.dataset.running = job.running ? "1" : "0";
      upEl.textContent = job.running ? "Running" : "Not running";
      li.appendChild(upEl);

      // THE HEARTBEAT, and it is a second fact rather than a nicer version of
      // the first. The indicator above says the process exists; this says the
      // monitor is still doing something. A monitor can be up and WEDGED -
      // process alive, polling stopped - which docs/POLICIES.md admits
      // monitor-dead cannot catch, and which reads as a green light for ever.
      // TKT-851's feeder stamps last_output_at every time a monitor speaks, so
      // there is finally something to read. TKT-863.
      //
      // Built inside this branch on purpose. `running` is present only for an
      // ENABLED MONITOR, so a cron job and a disabled monitor get no heartbeat
      // without anybody writing a second check to exclude them - the same
      // construction that already keeps a cron row from claiming "not running".
      const beat = document.createElement("div");
      beat.className = "jobs-card__beat";
      const spokeAt = job.last_output_at ? Date.parse(job.last_output_at) : NaN;

      // Never spoken is a THIRD state, not a bad one. A monitor started before
      // the feeder existed, or one that genuinely has not emitted a line, has
      // nothing here - and painting that either colour is a claim nobody
      // measured. His own word for it is in the card title: "red/green dim".
      //
      // WHEN SILENCE BECOMES RED IS NOT DECIDED HERE. A monitor has no cadence
      // in the record - its schedule is the literal string "monitor" - and
      // JOB-005 on the real board is legitimately quiet for over an hour,
      // because it speaks only when the owner has gone away. Q-115 asks him
      // where that expectation should come from and TKT-873 needs the same
      // answer for the police rule; until then this reports what it knows and
      // claims nothing it does not.
      //
      // RED IS DECIDED BY WHAT THE MONITOR ITSELF DECLARED. His answer to Q-115:
      // each monitor says how often it expects to speak, and one that declares
      // nothing is dim rather than judged. That is why JOB-005 - quiet for over
      // an hour because it only speaks when he has gone away - is not painted
      // red by a number that never fitted it.
      //
      // The comparison is against last_output_at ITSELF, never against
      // sinceWords' output: those words round both ways, so 89 minutes reads
      // "1 hour ago" and 91 reads "2 hours ago", and a threshold measured off
      // that label is wrong by up to half a unit in a direction nobody chose.
      const expectMs = job.expect_every ? job.expect_every * 60000 : 0;
      const silentFor = Date.now() - spokeAt;

      if (!Number.isFinite(spokeAt)) {
        beat.dataset.beat = "unknown";
        beat.textContent = "Never spoken";
      } else if (expectMs && silentFor > expectMs) {
        beat.dataset.beat = "stale";

        // "Silent for 40 minutes" - sinceWords ends in "ago", which reads
        // wrong after "Silent", and the expectation is shown in the minutes
        // the monitor actually declared rather than run through the same
        // rounding. Measured: a 3h09m silence against a 180-minute
        // expectation rendered as "Silent 3 hours ago, expects every 3 hours"
        // - both true, both rounded, and together they read as though the
        // monitor were not late at all. The decision never used those words;
        // only the label did, and the label is what a person acts on.
        beat.textContent =
          "Silent for " + sinceWords(silentFor).replace(" ago", "") +
          ", expects every " + job.expect_every + " min";
      } else {
        beat.dataset.beat = "beating";
        beat.textContent = "Last spoke " + sinceWords(silentFor);
      }
      li.appendChild(beat);
    }

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
    // TKT-882, absorbed here: a tail-style log below the card that was run,
    // rather than one line of status that the next click overwrites. His point
    // was that a job's output is the thing you came to look at, and a status
    // line can hold one sentence of it.
    //
    // BUILT ONCE PER CARD AND KEPT. Rebuilding it on each run would throw away
    // the previous run's output, which is exactly what the status line already
    // did wrong.
    const logBox = document.createElement("pre");
    logBox.className = "jobs-card__log";
    logBox.dataset.job = job.id;
    logBox.hidden = true;
    // Whatever this job has already said, put back on the card that was just
    // rebuilt under it.
    paintLog(logBox, job.id);

    play.addEventListener("click", () => {
      play.disabled = true;
      post("/jobs/run", { id: job.id })
        .then((result) => {
          jobsOk();
          const status = result && typeof result.status === "number" ? result.status : null;
          const output = result && result.output ? String(result.output).trim() : "";
          if (output) {
            rememberLines(job.id, output);
            paintLog(logBox, job.id);
          }
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

    // THE BUTTONS REFLECT THE STATE, his screenshot 6667 and TKT-883. A running
    // monitor is offered Stop and Restart; a stopped one is offered Start,
    // which is what the play button above already is. Offering Start on
    // something already running is the board inviting a second process beside
    // the first.
    //
    // `running` is only present when the process table could be read - it is
    // deliberately absent rather than false when the read failed - so an
    // unknown state is treated as not-running and the row simply keeps the
    // button it already had. TKT-861's indicator makes the same distinction.
    const isRunning = job.running === true;
    if (isRunning) {
      play.hidden = true;

      const stop = document.createElement("button");
      stop.className = "jobs-card__stop";
      stop.type = "button";
      stop.textContent = "Stop";
      stop.title = "Stop this monitor and clear the pid the board holds";
      stop.addEventListener("click", () => {
        stop.disabled = true;
        post("/jobs/stop", { id: job.id })
          .then(() => {
            jobsOk();
            loadJobs();
          })
          .catch((error) => jobsFail(job.id + ": " + error.message))
          .then(() => {
            stop.disabled = false;
          });
      });
      li.appendChild(stop);

      const restart = document.createElement("button");
      restart.className = "jobs-card__restart";
      restart.type = "button";
      restart.textContent = "Restart";
      restart.title = "Stop this monitor and start it again";
      restart.addEventListener("click", () => {
        restart.disabled = true;
        // Stop THEN start, in that order and only if the stop succeeded. A
        // restart that starts before the stop lands leaves two processes and a
        // board pointing at one of them, which is the orphan this epic exists
        // to prevent rather than create.
        post("/jobs/stop", { id: job.id })
          .then(() => post("/jobs/start", { id: job.id }))
          .then(() => {
            jobsOk();
            loadJobs();
          })
          .catch((error) => jobsFail(job.id + ": " + error.message))
          .then(() => {
            restart.disabled = false;
          });
      });
      li.appendChild(restart);
    }

    // The other half of the same criterion: an enabled job offers Disable, a
    // disabled one offers Enable. Through /jobs/save with nothing but the id
    // and the flag - job_update leaves every field it is not given alone, so a
    // toggle cannot quietly rewrite a command by sending a stale copy of it
    // back. That is why this does not reuse the editor's payload.
    const toggle = document.createElement("button");
    toggle.className = "jobs-card__toggle";
    toggle.type = "button";
    toggle.textContent = job.enabled ? "Disable" : "Enable";
    toggle.title = job.enabled
      ? "Stop this job being due, without deleting it"
      : "Let this job be due again";
    toggle.addEventListener("click", () => {
      toggle.disabled = true;
      post("/jobs/save", { id: job.id, enabled: !job.enabled })
        .then(() => {
          jobsOk();
          loadJobs();
        })
        .catch((error) => jobsFail(job.id + ": " + error.message))
        .then(() => {
          toggle.disabled = false;
        });
    });
    li.appendChild(toggle);

    // HIS COMPLAINT 1. The confirm is not ceremony: this removes a record that
    // may be the only thing pointing at a running process, and the engine will
    // refuse exactly that case - so the refusal is shown in the page's own
    // failure line rather than swallowed, and it names tira.job.stop.
    const remove = document.createElement("button");
    remove.className = "jobs-card__delete";
    remove.type = "button";
    remove.textContent = "Delete";
    remove.title = "Remove this job from the board";
    remove.addEventListener("click", () => {
      if (!window.confirm("Delete " + job.id + "? A running monitor must be stopped first.")) {
        return;
      }
      remove.disabled = true;
      post("/jobs/delete", { id: job.id })
        .then(() => {
          jobsOk();
          loadJobs();
        })
        .catch((error) => jobsFail(job.id + ": " + error.message))
        .then(() => {
          remove.disabled = false;
        });
    });
    li.appendChild(remove);

    li.appendChild(logBox);

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

  // Ageing only - this timer asks the server for nothing, which is why it is
  // not one of the polled routes t/479 governs. Every five seconds a line that
  // has passed a minute stops being yellow, so "recent" stays true rather than
  // being true only at the moment of the last reload.
  window.setInterval(() => {
    for (const box of jobsSection.querySelectorAll(".jobs-card__log")) {
      paintLog(box, box.dataset.job);
    }
  }, 5000);
}
