// Copyright (c) 2019 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.

import http
import json
import sync

const (
	NR_THREADS = 4
)

struct Story {
	title string
	url string
}

struct Fetcher {
mut:
	mu      &sync.Mutex
	ids     []int
	cursor  int
	wg      &sync.WaitGroup
}

fn (f mut Fetcher) fetch() {
	for {
		if f.cursor >= f.ids.len {
			return
		}
		id := f.ids[f.cursor]
		f.mu.lock()
		f.cursor++
		f.mu.unlock()
		cursor := f.cursor
		resp := http.get('https://hacker-news.firebaseio.com/v0/item/${id}.json') or {
			println('failed to fetch data from /v0/item/${id}.json')
			exit(1)
		}
		story := json.decode(Story, resp.text) or {
			println('failed to decode a story')
			exit(1)
		}
		println('#$cursor) $story.title | $story.url')
		f.wg.done()
	}
}

// Fetches top HN stories in 4 coroutines
fn main() {
	resp := http.get('https://hacker-news.firebaseio.com/v0/topstories.json') or {
		println('failed to fetch data from /v0/topstories.json')
		return
	}
	mut ids := json.decode([]int, resp.text) or {
		println('failed to decode topstories.json')
		return
	}
	if ids.len > 10 {
		// ids = ids[:10]
		mut tmp := [0].repeat(10)
		for i := 0 ; i < 10 ; i++ {
			tmp[i] = ids[i]
		}
		ids = tmp
	}
	
	wg := sync.new_waitgroup()
	mtx := sync.new_mutex()
	mut fetcher := &Fetcher{ids: ids mu: 0 wg: 0}
	fetcher.mu = &mtx
	fetcher.wg = &wg
	fetcher.wg.add(ids.len)
	for i := 0; i < NR_THREADS; i++ {
		go fetcher.fetch()
	}
	fetcher.wg.wait()
}

