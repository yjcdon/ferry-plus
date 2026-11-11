package ui

import (
	"context"
	"errors"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

var uploadDropOptions = transfer.DropOptions{Formats: []transfer.Format{transfer.FileList}}

type uploadSourceTarget struct{ jobID, relativePath string }

func (w *Workspace) chooseReplacementUploadSource(target uploadSourceTarget) {
	w.transfer.sourceTarget, w.transfer.sourceProblem = target, ""
	w.pickLocalItems(platform.ChooseUploadSource, func(items []platform.LocalReference, err error) {
		if err != nil {
			w.transfer.sourceProblem = err.Error()
		} else if len(items) != 0 && !w.quitting {
			w.transfer.sourceChecking = true
			go func() {
				err := w.jobs.RebindUploadSource(w.ctx, target.jobID, target.relativePath, items[0])
				w.window.Update(func() {
					w.transfer.sourceChecking = false
					if err != nil && !errors.Is(err, context.Canceled) {
						w.transfer.sourceProblem = err.Error()
					}
				})
			}()
		}
	})
}

func (w *Workspace) uploadFromCurrent() {
	if f := w.files[app.Provider(w.preferences.Page)]; f != nil {
		if _, ready := f.directory.Target(f.directory.Root()); ready && !f.busy {
			w.chooseUpload(f, f.directory.Root())
			return
		}
	}
	w.pickLocalItems(platform.ChooseUploadItems, func(items []platform.LocalReference, err error) {
		if err != nil {
			w.transfer.problem = err.Error()
		} else if len(items) != 0 {
			w.addUploadDraft(items)
		}
	})
}

func (w *Workspace) chooseUpload(f *directoryView, ref app.RemoteRef) {
	target, ok := f.directory.Target(ref)
	if !ok || f.busy || w.jobs == nil {
		return
	}
	f.problem = ""
	w.pickLocalItems(platform.ChooseUploadItems, func(items []platform.LocalReference, err error) {
		if err != nil {
			f.problem = err.Error()
		} else if len(items) != 0 {
			w.enqueueUpload(f, target, items, false)
		}
	})
}

func (w *Workspace) pickLocalItems(choose func(*mygo.Window, func([]platform.LocalReference, error)) func(), done func([]platform.LocalReference, error)) {
	w.window.Update(func() {
		if w.chooser != nil {
			return
		}
		w.chooser = choose(w.window, func(items []platform.LocalReference, err error) {
			w.window.Update(func() {
				w.chooser = nil
				done(items, err)
			})
		})
	})
}

func (w *Workspace) enqueueUpload(f *directoryView, target app.DirectoryTarget, items []platform.LocalReference, draft bool) {
	f.busy, f.problem = true, ""
	go func() {
		_, err := w.jobs.EnqueueUpload(target, items)
		w.window.Update(func() {
			f.busy = false
			if err != nil {
				f.problem = err.Error()
			} else if draft {
				w.uploadDraft = nil
			}
			w.refreshUploadDirectory(f)
		})
	}()
}

func (w *Workspace) directoryDrop(element ui.Element, f *directoryView, ref app.RemoteRef) bool {
	if w.jobs == nil || f.busy {
		return false
	}
	target, ready := f.directory.Target(ref)
	if !ready {
		return false
	}
	if drop, ok := ui.DropData(element, uploadDropOptions); ok {
		f.busy = true
		go func() {
			items, err := referencesFromDrop(drop)
			w.window.Update(func() {
				f.busy = false
				if err != nil {
					f.problem = err.Error()
				} else {
					w.enqueueUpload(f, target, items, false)
				}
			})
		}()
		return false
	}
	_, over := ui.DataDragOver(element, uploadDropOptions)
	return over
}

func (w *Workspace) draftDrop(element ui.Element) {
	if w.jobs == nil {
		return
	}
	if f := w.files[app.Provider(w.preferences.Page)]; f != nil {
		if _, ready := f.directory.Target(f.directory.Root()); ready {
			return
		}
	}
	if drop, ok := ui.DropData(element, uploadDropOptions); ok {
		go func() {
			items, err := referencesFromDrop(drop)
			w.window.Update(func() {
				if err != nil {
					w.transfer.problem = err.Error()
					return
				}
				w.addUploadDraft(items)
			})
		}()
	}
}

func (w *Workspace) addUploadDraft(items []platform.LocalReference) {
	seen := make(map[string]bool, len(w.uploadDraft))
	for _, previous := range w.uploadDraft {
		seen[previous.Path] = true
	}
	for _, item := range items {
		if !seen[item.Path] {
			w.uploadDraft = append(w.uploadDraft, item)
			seen[item.Path] = true
		}
	}
	w.preferences.Page = w.preferences.RecentProvider
	w.ensureDirectory(w.files[app.Provider(w.preferences.Page)])
}

func referencesFromDrop(drop transfer.Drop) ([]platform.LocalReference, error) {
	paths, err := drop.Data.Files()
	if err != nil {
		return nil, err
	}
	items := make([]platform.LocalReference, 0, len(paths))
	for _, path := range paths {
		item, err := platform.RememberLocalItem(path)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

func (w *Workspace) uploadDraftBar(c *ui.Context, f *directoryView) {
	if len(w.uploadDraft) == 0 {
		return
	}
	target, ready := f.directory.Target(f.directory.Root())
	ui.Toolbar(c, func() {
		ui.Textf(c, "%d 项待上传", len(w.uploadDraft))
		ui.Spacer(c)
		if ui.Button(c, "取消").Disabled(f.busy).Clicked() {
			w.uploadDraft = nil
		}
		if ui.PrimaryButton(c, "上传到当前目录").Disabled(!ready || f.busy).Clicked() {
			w.enqueueUpload(f, target, w.uploadDraft, true)
		}
	})
}
