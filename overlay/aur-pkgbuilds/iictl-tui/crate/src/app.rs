//! The renderer: a small ratatui app that draws a domain's option spec and
//! applies picks by shelling back out to `iictl`. It mutates nothing itself.
//!
//! UX contract (enforced structurally — domains cannot build a maze):
//!   * progressive disclosure — controls listed top-level; a `choice`/`list`
//!     opens ONE picker level deep, never deeper.
//!   * explicit done/cancel — `q`/`Esc` always exits; nothing loops by force.
//!   * mouse + keyboard — arrows/jk/Enter/Space/Tab + click-to-select + wheel.

use std::error::Error;
use std::io::{self, Stdout, Write};
use std::process::Command;
use std::time::Duration;

use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseButton,
    MouseEventKind,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph};
use ratatui::Terminal;

use crate::spec::{subst, Control, Opt, Spec};
use crate::theme::Theme;

type R<T> = Result<T, Box<dyn Error>>;
type Term = Terminal<CrosstermBackend<Stdout>>;

/// One row inside an open picker.
struct PickItem {
    value: String,
    label: String,
    /// choice: is this the current value · list: is it in `current`.
    marked: bool,
}

enum Mode {
    Browse,
    /// A picker open over control `idx`. `source` indexes a list control's
    /// `sources` (for dynamic `candidates`); ignored for inline options.
    Picker {
        idx: usize,
        items: Vec<PickItem>,
        state: ListState,
        source: usize,
    },
}

pub struct App {
    domain: String,
    iictl: String,
    spec: Spec,
    theme: Theme,
    sel: usize,
    mode: Mode,
    status: String,
    should_quit: bool,
    /// inner Rect of the controls list — for click-to-select hit testing.
    controls_area: Rect,
}

impl App {
    pub fn new(domain: String, iictl: String, spec: Spec, theme: Theme) -> App {
        App {
            domain,
            iictl,
            spec,
            theme,
            sel: 0,
            mode: Mode::Browse,
            status: "↑/↓ move · Enter open · Space toggle · q done".into(),
            should_quit: false,
            controls_area: Rect::default(),
        }
    }

    // ── terminal lifecycle ────────────────────────────────────────────────
    pub fn run(mut self) -> R<()> {
        let mut term = setup_terminal()?;
        let res = self.event_loop(&mut term);
        restore_terminal(&mut term)?;
        res
    }

    fn event_loop(&mut self, term: &mut Term) -> R<()> {
        while !self.should_quit {
            term.draw(|f| self.draw(f))?;
            if !event::poll(Duration::from_millis(200))? {
                continue;
            }
            match event::read()? {
                Event::Key(k) if k.kind != KeyEventKind::Release => {
                    self.on_key(k.code, term)?;
                }
                Event::Mouse(m) => self.on_mouse(m, term)?,
                Event::Resize(_, _) => {}
                _ => {}
            }
        }
        Ok(())
    }

    // ── key handling ──────────────────────────────────────────────────────
    // We branch on the mode discriminant first (matches!) rather than holding a
    // `&mut self.mode` borrow across the arms — the arms call `&mut self`
    // methods, which would alias that borrow.
    fn on_key(&mut self, code: KeyCode, term: &mut Term) -> R<()> {
        if matches!(self.mode, Mode::Picker { .. }) {
            match code {
                KeyCode::Char('q') | KeyCode::Esc | KeyCode::Left => self.mode = Mode::Browse,
                KeyCode::Up | KeyCode::Char('k') => self.picker_move(-1),
                KeyCode::Down | KeyCode::Char('j') => self.picker_move(1),
                KeyCode::Tab => self.cycle_source(term)?,
                KeyCode::Enter | KeyCode::Char(' ') => self.pick(term)?,
                _ => {}
            }
        } else {
            match code {
                KeyCode::Char('q') | KeyCode::Esc => self.should_quit = true,
                KeyCode::Up | KeyCode::Char('k') => self.move_sel(-1),
                KeyCode::Down | KeyCode::Char('j') => self.move_sel(1),
                KeyCode::Enter | KeyCode::Char(' ') | KeyCode::Right => self.activate(term)?,
                _ => {}
            }
        }
        Ok(())
    }

    fn on_mouse(&mut self, m: event::MouseEvent, _term: &mut Term) -> R<()> {
        match m.kind {
            MouseEventKind::ScrollDown => self.scroll(1),
            MouseEventKind::ScrollUp => self.scroll(-1),
            MouseEventKind::Down(MouseButton::Left) => {
                // Click-to-select in the top-level controls list.
                if matches!(self.mode, Mode::Browse) {
                    let a = self.controls_area;
                    if m.column >= a.x
                        && m.column < a.x + a.width
                        && m.row >= a.y
                        && m.row < a.y + a.height
                    {
                        let i = (m.row - a.y) as usize;
                        if i < self.spec.controls.len() {
                            self.sel = i;
                        }
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn move_sel(&mut self, delta: i32) {
        let n = self.spec.controls.len();
        if n == 0 {
            return;
        }
        let cur = self.sel as i32;
        self.sel = (cur + delta).rem_euclid(n as i32) as usize;
    }

    fn picker_move(&mut self, delta: i32) {
        if let Mode::Picker { state, items, .. } = &mut self.mode {
            move_list(state, items.len(), delta);
        }
    }

    fn scroll(&mut self, delta: i32) {
        if let Mode::Picker { state, items, .. } = &mut self.mode {
            move_list(state, items.len(), delta);
        } else {
            self.move_sel(delta);
        }
    }

    // ── activate a control (Browse → Picker, or flip a toggle) ─────────────
    fn activate(&mut self, term: &mut Term) -> R<()> {
        let Some(ctrl) = self.spec.controls.get(self.sel) else {
            return Ok(());
        };
        match ctrl.clone() {
            Control::Toggle {
                current,
                apply_on,
                apply_off,
                ..
            } => {
                let argv = if current { &apply_off } else { &apply_on };
                self.apply(term, &subst(argv, "", None))?;
            }
            Control::Choice { .. } | Control::List { .. } => self.open_picker(term)?,
        }
        Ok(())
    }

    fn open_picker(&mut self, term: &mut Term) -> R<()> {
        let idx = self.sel;
        let items = self.build_items(idx, 0, term)?;
        let mut state = ListState::default();
        if !items.is_empty() {
            // start on the current value for a choice, else the top.
            let start = items.iter().position(|i| i.marked).unwrap_or(0);
            state.select(Some(start));
        }
        self.mode = Mode::Picker {
            idx,
            items,
            state,
            source: 0,
        };
        Ok(())
    }

    /// Build the picker rows for control `idx`. For a list control with no inline
    /// `options` but a `candidates` argv, fetch the candidate set for `source`.
    fn build_items(&self, idx: usize, source: usize, term: &mut Term) -> R<Vec<PickItem>> {
        match &self.spec.controls[idx] {
            Control::Choice {
                current, options, ..
            } => Ok(options
                .iter()
                .map(|o| PickItem {
                    value: o.value.clone(),
                    label: o.label().to_string(),
                    marked: &o.value == current,
                })
                .collect()),
            Control::List {
                current,
                options,
                candidates,
                sources,
                ..
            } => {
                let opts: Vec<Opt> = if !options.is_empty() || candidates.is_empty() {
                    options.clone()
                } else {
                    // dynamic source-driven candidates (#48 owns the resolvers).
                    let src = sources.get(source).map(|s| s.as_str()).unwrap_or("");
                    self.fetch_candidates(&subst(candidates, "", Some(src)), term)?
                };
                Ok(opts
                    .iter()
                    .map(|o| PickItem {
                        value: o.value.clone(),
                        label: o.label().to_string(),
                        marked: current.iter().any(|c| c == &o.value),
                    })
                    .collect())
            }
            Control::Toggle { .. } => Ok(vec![]),
        }
    }

    /// Run a `candidates` argv (it prints a JSON array of options) and parse it.
    fn fetch_candidates(&self, argv: &[String], _term: &mut Term) -> R<Vec<Opt>> {
        let out = Command::new(&self.iictl).args(argv).output()?;
        if !out.status.success() {
            return Err(format!("candidates verb failed: {} {:?}", self.iictl, argv).into());
        }
        let opts: Vec<Opt> = serde_json::from_slice(&out.stdout)?;
        Ok(opts)
    }

    fn cycle_source(&mut self, term: &mut Term) -> R<()> {
        let (idx, source) = match &self.mode {
            Mode::Picker { idx, source, .. } => (*idx, *source),
            _ => return Ok(()),
        };
        // clone the source names so no borrow of self.spec is held across the
        // later `self.status` / `self.mode` mutations.
        let sources: Vec<String> = match &self.spec.controls[idx] {
            Control::List { sources, .. } => sources.clone(),
            _ => return Ok(()),
        };
        if sources.len() < 2 {
            return Ok(());
        }
        let next = (source + 1) % sources.len();
        let items = self.build_items(idx, next, term)?;
        let mut state = ListState::default();
        if !items.is_empty() {
            state.select(Some(0));
        }
        self.status = format!("source: {}", sources[next]);
        self.mode = Mode::Picker {
            idx,
            items,
            state,
            source: next,
        };
        Ok(())
    }

    /// Enter/Space inside a picker: apply the highlighted option.
    fn pick(&mut self, term: &mut Term) -> R<()> {
        let (idx, value, marked) = {
            let Mode::Picker { idx, items, state, .. } = &self.mode else {
                return Ok(());
            };
            let Some(cur) = state.selected() else {
                return Ok(());
            };
            let Some(item) = items.get(cur) else {
                return Ok(());
            };
            (*idx, item.value.clone(), item.marked)
        };

        match self.spec.controls[idx].clone() {
            Control::Choice { apply, .. } => {
                self.apply(term, &subst(&apply, &value, None))?;
                self.mode = Mode::Browse;
            }
            Control::List {
                apply_add,
                apply_remove,
                ..
            } => {
                let argv = if marked { &apply_remove } else { &apply_add };
                self.apply(term, &subst(argv, &value, None))?;
                // refresh marks and stay in the picker (optional multi-edit).
                self.refresh_picker(term)?;
            }
            Control::Toggle { .. } => {}
        }
        Ok(())
    }

    fn refresh_picker(&mut self, term: &mut Term) -> R<()> {
        let (idx, source, selected) = {
            let Mode::Picker { idx, source, state, .. } = &self.mode else {
                return Ok(());
            };
            (*idx, *source, state.selected())
        };
        let items = self.build_items(idx, source, term)?;
        let mut state = ListState::default();
        if !items.is_empty() {
            let s = selected.unwrap_or(0).min(items.len() - 1);
            state.select(Some(s));
        }
        self.mode = Mode::Picker {
            idx,
            items,
            state,
            source,
        };
        Ok(())
    }

    /// Run an apply argv with the TUI suspended so the user sees pacman/paru
    /// output, then reload the spec to reflect the new state.
    fn apply(&mut self, term: &mut Term, argv: &[String]) -> R<()> {
        if argv.is_empty() {
            return Ok(());
        }
        suspend(term, || {
            println!("\n\x1b[1m>> iictl {}\x1b[0m\n", argv.join(" "));
            let status = Command::new(&self.iictl).args(argv).status();
            match status {
                Ok(s) if s.success() => println!("\n\x1b[32m[ok]\x1b[0m done."),
                Ok(s) => println!("\n\x1b[31m[failed]\x1b[0m exit {:?}", s.code()),
                Err(e) => println!("\n\x1b[31m[error]\x1b[0m {e}"),
            }
            print!("press Enter to return… ");
            let _ = io::stdout().flush();
            let mut buf = String::new();
            let _ = io::stdin().read_line(&mut buf);
        })?;
        term.clear()?;
        self.status = format!("applied: iictl {}", argv.join(" "));
        // Reload the spec so `current` reflects what just changed.
        match crate::load_spec(&self.domain) {
            Ok(s) => self.spec = s,
            Err(e) => self.status = format!("applied, but reload failed: {e}"),
        }
        Ok(())
    }

    // ── rendering ─────────────────────────────────────────────────────────
    fn draw(&mut self, f: &mut ratatui::Frame) {
        let full = f.area();
        let t = &self.theme;
        let base = Style::default().bg(t.background).fg(t.on_surface);
        f.render_widget(Block::default().style(base), full);

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(3), Constraint::Length(2)])
            .split(full);

        // main panel
        let title = format!(" {} ", self.spec.title());
        let panel = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(t.primary))
            .title(Span::styled(
                title,
                Style::default()
                    .fg(t.primary)
                    .add_modifier(Modifier::BOLD),
            ))
            .style(Style::default().bg(t.background));
        let inner = panel.inner(chunks[0]);
        f.render_widget(panel, chunks[0]);
        self.controls_area = inner;
        self.draw_controls(f, inner);

        // footer: status + keys
        let keys = match self.mode {
            Mode::Browse => "↑/↓ move · Enter open · Space toggle · click select · q quit",
            Mode::Picker { .. } => "↑/↓ move · Enter/Space apply · Tab source · Esc back",
        };
        let footer = Paragraph::new(vec![
            Line::from(Span::styled(
                self.status.clone(),
                Style::default().fg(t.on_surface_variant),
            )),
            Line::from(Span::styled(keys, Style::default().fg(t.outline))),
        ])
        .style(Style::default().bg(t.background));
        f.render_widget(footer, chunks[1]);

        // picker overlay
        if let Mode::Picker { .. } = self.mode {
            self.draw_picker(f, full);
        }
    }

    fn draw_controls(&self, f: &mut ratatui::Frame, area: Rect) {
        let t = &self.theme;
        if self.spec.controls.is_empty() {
            let p = Paragraph::new(Line::from(Span::styled(
                "this domain advertises no controls",
                Style::default().fg(t.on_surface_variant),
            )));
            f.render_widget(p, area);
            return;
        }
        let mut lines: Vec<Line> = Vec::new();
        for (i, ctrl) in self.spec.controls.iter().enumerate() {
            let selected = i == self.sel;
            let marker = if selected { "▸ " } else { "  " };
            let label = ctrl.label();
            let value = control_summary(ctrl);
            let style = if selected {
                Style::default()
                    .bg(t.primary_container)
                    .fg(t.on_primary_container)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(t.on_surface)
            };
            lines.push(Line::from(vec![
                Span::styled(format!("{marker}{label}"), style),
                Span::styled("  ", style),
                Span::styled(value, Style::default().fg(t.primary)),
            ]));
        }
        f.render_widget(Paragraph::new(lines), area);
    }

    fn draw_picker(&mut self, f: &mut ratatui::Frame, full: Rect) {
        let t = &self.theme;
        let (idx, source) = match &self.mode {
            Mode::Picker { idx, source, .. } => (*idx, *source),
            _ => return,
        };
        let label = self.spec.controls[idx].label().to_string();
        let is_list = matches!(self.spec.controls[idx], Control::List { .. });
        let source_hint = match &self.spec.controls[idx] {
            Control::List { sources, .. } if sources.len() > 1 => {
                format!("  [source: {} — Tab]", sources[source])
            }
            _ => String::new(),
        };

        let area = centered_rect(60, 70, full);
        f.render_widget(Clear, area);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(t.primary))
            .title(Span::styled(
                format!(" {label}{source_hint} "),
                Style::default().fg(t.primary).add_modifier(Modifier::BOLD),
            ))
            .style(Style::default().bg(t.surface_container));

        let Mode::Picker { items, state, .. } = &mut self.mode else {
            return;
        };
        let rows: Vec<ListItem> = items
            .iter()
            .map(|it| {
                let mark = if is_list {
                    if it.marked {
                        "[x] "
                    } else {
                        "[ ] "
                    }
                } else if it.marked {
                    "(•) "
                } else {
                    "( ) "
                };
                let fg = if it.marked { t.primary } else { t.on_surface };
                ListItem::new(Line::from(vec![
                    Span::styled(mark, Style::default().fg(t.primary)),
                    Span::styled(it.label.clone(), Style::default().fg(fg)),
                ]))
            })
            .collect();
        let list = List::new(rows).block(block).highlight_style(
            Style::default()
                .bg(t.primary_container)
                .fg(t.on_primary_container)
                .add_modifier(Modifier::BOLD),
        );
        f.render_stateful_widget(list, area, state);
    }
}

// ── free helpers ──────────────────────────────────────────────────────────
fn control_summary(ctrl: &Control) -> String {
    match ctrl {
        Control::Choice { current, .. } => {
            if current.is_empty() {
                "—".into()
            } else {
                current.clone()
            }
        }
        Control::List { current, .. } => {
            if current.is_empty() {
                "none selected".into()
            } else if current.len() <= 3 {
                current.join(", ")
            } else {
                format!("{} selected", current.len())
            }
        }
        Control::Toggle { current, .. } => {
            if *current {
                "◉ on".into()
            } else {
                "○ off".into()
            }
        }
    }
}

fn move_list(state: &mut ListState, len: usize, delta: i32) {
    if len == 0 {
        return;
    }
    let cur = state.selected().unwrap_or(0) as i32;
    let next = (cur + delta).rem_euclid(len as i32) as usize;
    state.select(Some(next));
}

fn centered_rect(pct_x: u16, pct_y: u16, r: Rect) -> Rect {
    let v = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - pct_y) / 2),
            Constraint::Percentage(pct_y),
            Constraint::Percentage((100 - pct_y) / 2),
        ])
        .split(r);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - pct_x) / 2),
            Constraint::Percentage(pct_x),
            Constraint::Percentage((100 - pct_x) / 2),
        ])
        .split(v[1])[1]
}

fn setup_terminal() -> R<Term> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let term = Terminal::new(CrosstermBackend::new(stdout))?;
    Ok(term)
}

fn restore_terminal(term: &mut Term) -> R<()> {
    disable_raw_mode()?;
    execute!(
        term.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    term.show_cursor()?;
    Ok(())
}

/// Drop out of the alternate screen + raw mode, run `body` with normal stdio,
/// then return to the TUI. Used so long apply commands show their own output.
fn suspend<F: FnOnce()>(term: &mut Term, body: F) -> R<()> {
    disable_raw_mode()?;
    execute!(
        term.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    body();
    enable_raw_mode()?;
    execute!(
        term.backend_mut(),
        EnterAlternateScreen,
        EnableMouseCapture
    )?;
    Ok(())
}
