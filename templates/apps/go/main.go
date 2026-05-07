// Minimal "hello, devstack" Go HTTP server shipped by dev-strap.
// Lives at templates/apps/go/main.go in the factory; copied to ./app/main.go
// at bootstrap time so `./devstack.sh start` succeeds before the user has
// written any application code.
//
// Overwrite this freely — Air will live-reload on save.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"service":"app","status":"ok","stub":true,"path":%q}`+"\n", r.URL.Path)
	})

	addr := ":" + port
	log.Printf("[devstack-stub] listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}
