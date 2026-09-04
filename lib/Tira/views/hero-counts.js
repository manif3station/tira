// What the top right says, and what it stays quiet about.
//
// His words, 6812: "Add X monitor(s) stopped if any / X schedual jobs is
// disabled if any along the line of `0 questions awaiting - 0 tasks` / Same for
// quesitons and tasks, if 0 no need to show / At the top right of the screen".
//
// TWO REQUESTS. The counts are the obvious half. The other is a change to what
// already shipped: the header used to print "0 questions awaiting - 0 tasks" on
// a board with nothing outstanding, which spends the corner somebody checks for
// trouble on the news that there is none. Adding two counts without that would
// have made it worse - a stopped monitor arriving beside two zeroes.
//
// A STOPPED MONITOR IS WHY THIS EPIC EXISTS. Three standing hunts died on
// 2026-09-02 and nobody noticed for hours, because a loop that has stopped and
// a loop with nothing to report look identical from outside. This is the same
// fact monitor-dead announces on the bridge, in the place he is already
// looking. TKT-924.
const heroCounts = document.querySelector(".hero__counts");

if (heroCounts) {
  const plural = (n, word) => n + " " + word + (n === 1 ? "" : "s");

  // Null until the first fetch answers, and that is deliberate: zero and
  // "not asked yet" are different, and a count that has not arrived must not
  // be rendered as an absence of trouble.
  let taskTotal = null;
  let stoppedTotal = null;
  let disabledTotal = null;

  const paintHeroCounts = () => {
    const questionTotal = document.querySelectorAll(".card--waiting").length;
    const parts = [];

    // EVERY PART IS CONDITIONAL, including the two that were unconditional
    // before. A zero says nothing worth the space it takes.
    if (questionTotal) {
      parts.push(plural(questionTotal, "question") + " awaiting");
    }
    if (taskTotal) {
      parts.push(plural(taskTotal, "task"));
    }
    if (stoppedTotal) {
      parts.push(plural(stoppedTotal, "monitor") + " stopped");
    }
    if (disabledTotal) {
      parts.push(plural(disabledTotal, "job") + " disabled");
    }

    // Empty rather than a stray separator when there is nothing to say, which
    // is what "if any" means at the end of a line of four.
    heroCounts.textContent = parts.length ? parts.join(" \u00b7 ") : "";
  };

  const refreshTaskTotal = () =>
    fetch("/tasklist", { cache: "no-store" })
      .then((response) => (response.ok ? response.json() : []))
      .then((list) => {
        taskTotal = Array.isArray(list) ? list.length : 0;
        paintHeroCounts();
      })
      .catch(() => {});

  // THE VERDICT IS THE ENGINE'S, NOT THE PAGE'S. `running` is set by the jobs
  // provider from Tira::Job::job_monitor_alive - the same call monitor-dead
  // makes and the same one the row indicator shows (TKT-861). A count worked
  // out here from a pid would be a second opinion, and the top of the page
  // disagreeing with the row halfway down it is worse than either being wrong.
  //
  // === false RATHER THAN FALSY, and the difference is the whole of his third
  // criterion. The provider sets `running` only for an ENABLED monitor, so a
  // disabled one and a cron job have no such field: absent means "not
  // applicable" and must not be counted as stopped. A disabled monitor is
  // counted once, as disabled, because it is off on purpose - which is also
  // why monitor-dead stays silent about it.
  const refreshJobTotals = () =>
    fetch("/jobs", { cache: "no-store" })
      .then((response) => (response.ok ? response.json() : []))
      .then((jobs) => {
        const rows = Array.isArray(jobs) ? jobs : [];
        stoppedTotal = rows.filter((job) => job.running === false).length;
        disabledTotal = rows.filter((job) => !job.enabled).length;
        paintHeroCounts();
      })
      .catch(() => {});

  document.querySelectorAll(".board").forEach((board) =>
    new MutationObserver(paintHeroCounts).observe(board, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["hidden", "class"],
    })
  );

  paintHeroCounts();
  refreshTaskTotal();
  refreshJobTotals();
  setInterval(refreshTaskTotal, 60000);
  setInterval(refreshJobTotals, 60000);
}

// THE STICKY HEADER'S OWN HALF, untouched by TKT-924 and kept here because it
// is where it has always been. TKT-797: the hero shrinks once the board has
// scrolled, so the counts stay in view without the header taking a third of a
// phone screen. Restored verbatim after I rewrote this file having read only
// its first line - the fault t/466 caught within a minute.
let heroScrollArmed = false;
const heroEl = document.querySelector(".hero");

if (heroEl) {
  const applyHeroScroll = () =>
    heroEl.classList.toggle("hero--compact", window.scrollY > 24);

  if (!heroScrollArmed) {
    heroScrollArmed = true;
    window.addEventListener("scroll", applyHeroScroll, { passive: true });
    applyHeroScroll();
  }
}
