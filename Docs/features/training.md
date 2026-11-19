# Training

The Training extension fine-tunes models on your Mac with the MLX-VLM trainer.
Enable it under **Extensions**; it adds a **Training** page to the sidebar.

## What it does

- **New Run** shows a form built from the trainer's own option list. Pick a task
  and an algorithm, fill in the model and data, and leave anything else empty to
  keep its default. **Check** validates the settings without starting.
- The run list shows every run with its status. Selecting one shows progress, the
  latest metrics, the saved weights, and the end of its log.
- **Stop** ends a run and keeps the checkpoints saved so far.

Runs are separate background processes. They keep going when Nativ is closed, and
Nativ picks them up again on the next launch.

## Training type

**LoRA**, **DoRA**, and **Full weights** are a switch at the top of the form when
the algorithm offers them. LoRA trains small adapter layers and is the default;
DoRA is a little heavier; full training updates every weight and needs far more
memory.

## Using the trained model

A run saves its weights in its run folder. With LoRA or DoRA that is an adapter,
which only works on top of its base model.

Turn on **Merge after training and add to my models** to also get a model you can
pick in the model list. When the run ends, the trained weights are fused into a
full, standalone model saved in Nativ's model folder as
`nativ-trained/<name>-<date>`. It works with all three training types, and a run
that stops at a time or memory limit still saves its merged model. The model can
ask for the same thing with `merge_into_library` on `start_training`.

A merged model is a full copy, so it uses as much disk space as the base model.

## Charts

Each run has charts of its metrics over time, on its page and in a **Training**
section of the Dashboard. The charts are built from what the run reported, so the
set changes with the algorithm: supervised training shows loss and token accuracy,
while preference and reward algorithms add their own (reward accuracy, margins,
and so on). Training and validation values share a chart. Learning rate, speed,
and peak memory are shown for every run.

## Nothing is hard-coded

Nativ does not know which algorithms, modalities, or options exist. It asks the
trainer (`mlx_vlm.train_runs describe`) and renders what comes back, so a new
algorithm or modality in MLX-VLM appears on the page after Nativ ships that
MLX-VLM version, with no change to Nativ.

## Usage limits

**Usage Limits** sets caps that apply to every run on this Mac, including runs an
agent starts. An empty field means no limit.

| Limit | At the limit |
|---|---|
| Runs at the same time | A new run is refused. Default: 1. |
| Runs per day | A new run is refused. |
| Iterations per run | A longer run is refused when checked or started. |
| Minutes per run | The run saves its weights and ends as **Capped**. |
| Memory per run (GB) | The run saves its weights and ends as **Capped**. |

A capped run is not a failure: its weights are saved and it can be continued in a
new run. The limits are stored in `limits.json` in the runs folder.

## Where things live

| Path | Contents |
|---|---|
| `~/.mlx-vlm/runs/<run>/` | `config.json`, `run.json`, `train.log`, `progress.jsonl`, `adapters/` |
| `~/.mlx-vlm/runs/limits.json` | The usage limits |
| `~/.mlx-vlm/bin/nativ-train-runs` | Launcher written by the extension |

The runs folder is the trainer's default, so runs started from a terminal with
`python -m mlx_vlm.train_runs` appear on the page too.

## Letting the model train

The extension is built for the model as much as for you. While it is enabled, the
model has its own training tools and can run the whole job from a chat request
such as "fine-tune this model on my dataset for two epochs":

| Tool | What the model uses it for |
|---|---|
| `list_training_modes` | Learn the algorithms, then one algorithm's options |
| `training_limits` | Read your usage limits and current usage |
| `validate_model_support` | Check a model can be trained |
| `inspect_dataset` | Check a dataset loads; see splits and columns |
| `check_training_config` | Validate options before starting |
| `start_training` | Start a run in the background |
| `training_status` | Follow progress and metrics |
| `training_log` | Read the end of a run's log |
| `list_training_runs` | List recent runs |
| `stop_training` | Stop a run, keeping its checkpoints |

Apply the **Training** Kit to turn on the extension, these tools, and a skill that
teaches the model the flow: read the trainer's options, check before starting,
follow the run, and respect your limits. The tools are offered to the model only
while the extension is enabled, and each one can be switched off under **Tools**.

Runs the model starts appear on the Training page like your own, and your usage
limits apply to them. When a limit refuses or cuts off a run, the model is told
which limit and is instructed to say so rather than work around it.

The extension also writes a launcher, `~/.mlx-vlm/bin/nativ-train-runs`, for use
from a terminal: it runs the same commands with Nativ's Python.

## Requirements

The bundled MLX-VLM must include `mlx_vlm.train_runs`. With an older bundle the
page says so instead of showing the form. To try a newer MLX-VLM before it is
bundled, point Nativ at another Python that has it:

```sh
defaults write io.github.blaizzy.nativ nativ.training.pythonPath /path/to/python3
```

Local development builds use the bundle identifier `dev.local.Nativ` instead.

Remove the key to return to the bundled runtime.
